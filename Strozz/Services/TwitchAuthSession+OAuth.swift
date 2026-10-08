import Foundation

extension TwitchAuthSession {
    /// Refreshes the OAuth access token using the persisted refresh token.
    /// If no refresh token exists, callers should prompt the user to sign in again.
    func refreshAccessTokenIfNeeded(force: Bool = false) async throws -> String {
        if !force, let accessToken {
            return accessToken
        }
        return try await runTokenRefresh(rejectedAccessToken: nil)
    }

    /// Recovers from a 401 without needlessly rotating again when another process
    /// has already published a replacement access token to the shared store.
    func recoverAccessToken(afterUnauthorized rejectedAccessToken: String) async throws -> String {
        try await runTokenRefresh(rejectedAccessToken: rejectedAccessToken)
    }

    private func runTokenRefresh(rejectedAccessToken: String?) async throws -> String {
        // Join an already-running refresh instead of starting a second one.
        // This is what stops the in-app services (followed channels, playback,
        // chat) from racing each other onto the same single-use refresh token.
        if let refreshInFlight {
            return try await refreshInFlight.value
        }

        let task = Task { () throws -> String in
            try await performTokenRefresh(rejectedAccessToken: rejectedAccessToken)
        }
        let generation = sessionGeneration
        refreshInFlight = task
        defer { if sessionGeneration == generation { refreshInFlight = nil } }
        return try await task.value
    }

    private func performTokenRefresh(rejectedAccessToken: String?) async throws -> String {
        guard let clientID else {
            throw TwitchAuthRefreshError.missingClientID
        }

        // Always start from the persisted source of truth. If the token that
        // triggered a 401 has already been replaced, use the replacement instead
        // of spending another refresh token.
        try reloadTokensFromStore()
        if credentialCloudOwner != nil {
            guard let cloudSync else { throw TwitchSyncError.unavailable }
            return try await cloudSync.renew(rejectedAccessToken: rejectedAccessToken)
        }
        if cloudSync?.isBusy == true { throw TwitchSyncError.busy }
        if let rejectedAccessToken,
           let storedAccessToken = accessToken,
           storedAccessToken != rejectedAccessToken {
            return storedAccessToken
        }
        guard let currentRefreshToken = refreshToken else {
            throw TwitchAuthRefreshError.missingRefreshToken
        }

        do {
            let token = try await requestRefreshToken(
                clientID: clientID, refreshToken: currentRefreshToken)
            try Task.checkCancellation()
            return try applyRefreshedTokens(token)
        } catch let error as TwitchAuthHTTPError where isInvalidRefreshError(error) {
            // A concurrent app request may have published a replacement while
            // this request was in flight. Reload once before declaring the
            // session dead.
            try reloadTokensFromStore()
            if let rejectedAccessToken,
               let storedAccessToken = accessToken,
               storedAccessToken != rejectedAccessToken {
                return storedAccessToken
            }
            if let reloaded = refreshToken, reloaded != currentRefreshToken {
                do {
                    let token = try await requestRefreshToken(
                        clientID: clientID, refreshToken: reloaded)
                    try Task.checkCancellation()
                    return try applyRefreshedTokens(token)
                } catch let retryError as TwitchAuthHTTPError
                    where isInvalidRefreshError(retryError) {
                    // Both tokens are genuinely invalid — fall through to sign-out.
                }
                // A transient (e.g. network) failure on the retry propagates
                // without wiping the session.
            }
            clearStoredAuthState()
            errorMessage = "Session expired. Sign in again to reconnect Twitch."
            throw TwitchAuthRefreshError.sessionExpired
        }
    }

    /// Saves the pair in private Keychain storage and mirrors only the access
    /// token into the shared Top Shelf Keychain item.
    @discardableResult
    private func applyRefreshedTokens(_ token: DeviceTokenResponse) throws -> String {
        guard var credential = storedCredential else { throw TwitchAuthRefreshError.sessionExpired }
        credential.accessToken = token.accessToken
        if let next = token.refreshToken, !next.isEmpty { credential.refreshToken = next }
        try useCredential(credential)
        return token.accessToken
    }

    /// Pulls the latest persisted tokens from Keychain before
    /// any refresh/recovery decision.
    private func reloadTokensFromStore() throws {
        if let stored = try readSecureCredential() {
            accessToken = stored.accessToken
            refreshToken = stored.refreshToken
            credentialCloudOwner = stored.cloudOwner
        }
    }

    func startSessionValidation() {
        guard clientIDValidationIssue == nil,
              isAuthenticated,
              accessToken != nil || refreshToken != nil else { return }
        startValidationLoop(validateImmediately: true)
    }

    func validateSessionIfNeeded(force: Bool = false) async {
        guard clientIDValidationIssue == nil,
              isAuthenticated,
              let expectedClientID = clientID else { return }

        if !force,
           let lastValidatedAt,
           Date().timeIntervalSince(lastValidatedAt) < Self.validationInterval {
            return
        }

        let currentAccessToken: String
        let generation = sessionGeneration
        if let accessToken {
            currentAccessToken = accessToken
        } else {
            do {
                currentAccessToken = try await refreshAccessTokenIfNeeded(force: true)
            } catch {
                return
            }
        }

        do {
            let identity = try await requestValidatedIdentity(accessToken: currentAccessToken)
            guard generation == sessionGeneration, accessToken == currentAccessToken else { return }
            applyValidatedIdentity(identity, expectedClientID: expectedClientID)
        } catch let error as TwitchAuthHTTPError where error.status == 401 {
            do {
                let recovered = try await recoverAccessToken(
                    afterUnauthorized: currentAccessToken)
                let identity = try await requestValidatedIdentity(accessToken: recovered)
                guard generation == sessionGeneration, accessToken == recovered else { return }
                applyValidatedIdentity(identity, expectedClientID: expectedClientID)
            } catch let refreshError as TwitchAuthRefreshError {
                if case .missingRefreshToken = refreshError {
                    isAuthenticated = false
                    errorMessage = "Session expired. Sign in again to reconnect Twitch."
                }
            } catch {
                // Network and server failures are transient. Preserve credentials
                // and retry validation on the next foreground/hourly check.
            }
        } catch {
            // Validation is best-effort during transient network/server failures;
            // never discard a session unless Twitch rejects its refresh token.
        }
    }

    private func applyValidatedIdentity(
        _ identity: OAuthValidateResponse,
        expectedClientID: String
    ) {
        guard identity.clientID.caseInsensitiveCompare(expectedClientID) == .orderedSame else {
            isAuthenticated = false
            errorMessage =
                "The saved Twitch session belongs to a different Twitch client. Restore the matching client configuration or sign in again."
            return
        }

        userID = identity.userID
        userLogin = identity.login
        isAuthenticated = true
        errorMessage = nil
        let now = Date()
        lastValidatedAt = now
    }

    private func startValidationLoop(validateImmediately: Bool = false) {
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            if validateImmediately {
                guard let self else { return }
                await self.validateSessionIfNeeded(force: true)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.validationInterval))
                } catch {
                    return
                }
                guard let self else { return }
                await self.validateSessionIfNeeded(force: true)
            }
        }
    }

    func beginDeviceCodeSignIn(useSavedConnection: Bool = true) async {
        errorMessage = nil

        guard !isAuthenticated, !isAuthenticating, !isRestoringConnection else { return }
        let attempt = UUID()
        signInAttempt = attempt
        if useSavedConnection, let cloudSync {
            isRestoringConnection = true
            statusMessage = "Checking your saved connection..."
            let needsApproval = await cloudSync.restoreBeforeSignIn()
            guard !Task.isCancelled, attempt == signInAttempt else { return }
            isRestoringConnection = false
            statusMessage = nil
            guard needsApproval else {
                if !isAuthenticated { errorMessage = cloudSync.errorMessage }
                return
            }
        }
        if let issue = clientIDValidationIssue {
            errorMessage = issue
            return
        }
        guard let clientID else { return }

        isAuthenticating = true
        sessionGeneration = UUID()
        statusMessage = "Requesting Twitch sign-in code..."

        do {
            let response = try await requestDeviceCode(clientID: clientID)
            guard !Task.isCancelled, attempt == signInAttempt else { return }
            activationCode = response.userCode
            verificationURI = response.verificationURI
            verificationURIComplete = response.verificationURIComplete
            statusMessage = "Open the link and enter the code to finish sign-in."

            pollTask?.cancel()
            pollTask = Task { [weak self] in
                await self?.pollForAccessToken(
                    deviceCode: response.deviceCode,
                    interval: max(response.interval, 2),
                    expiresIn: response.expiresIn,
                    clientID: clientID
                )
            }
        } catch {
            guard !Task.isCancelled, attempt == signInAttempt else { return }
            isAuthenticating = false
            errorMessage = "Could not start Twitch sign-in: \(describe(error))"
            statusMessage = nil
        }
    }

    func cancelSignIn() {
        signInAttempt = UUID()
        isRestoringConnection = false
        pollTask?.cancel()
        pollTask = nil
        isAuthenticating = false
        statusMessage = nil
        activationCode = nil
        verificationURI = nil
        verificationURIComplete = nil
    }

    private func pollForAccessToken(deviceCode: String, interval: Int, expiresIn: Int, clientID: String) async {
        let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollSeconds = interval

        while Date() < expiryDate && !Task.isCancelled {
            do {
                let token = try await requestToken(clientID: clientID, deviceCode: deviceCode)
                try await finishSignIn(token: token, clientID: clientID)
                return
            } catch let error as OAuthPollingError {
                switch error {
                case .authorizationPending:
                    statusMessage = "Waiting on you…"
                case .slowDown:
                    pollSeconds += 2
                    statusMessage = "Waiting on you…"
                case .accessDenied:
                    errorMessage = "Twitch sign-in was canceled."
                    isAuthenticating = false
                    return
                case .expiredToken:
                    errorMessage = "Twitch sign-in code expired. Try again."
                    isAuthenticating = false
                    return
                }
            } catch {
                errorMessage = "Sign-in failed: \(describe(error))"
                isAuthenticating = false
                return
            }

            do {
                try await Task.sleep(for: .seconds(pollSeconds))
            } catch {
                isAuthenticating = false
                return
            }
        }

        if !Task.isCancelled {
            errorMessage = "Twitch sign-in timed out."
            isAuthenticating = false
        }
    }

    private func finishSignIn(token: DeviceTokenResponse, clientID: String) async throws {
        let identity = try await requestValidatedIdentity(accessToken: token.accessToken)
        let profile = try? await requestUserProfile(accessToken: token.accessToken, clientID: clientID, userID: identity.userID)
        try Task.checkCancellation()
        guard identity.clientID == clientID else { throw TwitchSyncError.invalidAccount }

        let resolvedLogin = profile?.login ?? identity.login
        let resolvedDisplayName = profile?.displayName ?? identity.login
        let resolvedImageURL = profile?.profileImageURL.flatMap(URL.init(string:))
        let credential = TwitchCredential(accessToken: token.accessToken, refreshToken: token.refreshToken,
          userID: identity.userID, clientID: clientID, login: resolvedLogin,
          displayName: resolvedDisplayName, imageURL: resolvedImageURL)
        try useCredential(credential)
        self.isAuthenticating = false
        self.statusMessage = "Signed in as \(resolvedDisplayName)."
        self.errorMessage = nil
        lastValidatedAt = Date()
        await cloudSync?.signedIn(credential)
        startValidationLoop()
    }

    func validateSyncedCredential(_ credential: TwitchCredential) async throws {
        guard credential.clientID == clientID else { throw TwitchSyncError.invalidAccount }
        let identity = try await requestValidatedIdentity(accessToken: credential.accessToken)
        try Task.checkCancellation()
        guard identity.clientID == credential.clientID, identity.userID == credential.userID else {
            throw TwitchSyncError.invalidAccount
        }
    }

    func refreshSyncedCredential(_ credential: TwitchCredential) async throws -> TwitchCredential {
        guard credential.clientID == clientID, let refresh = credential.refreshToken else {
            throw TwitchSyncError.invalidAccount
        }
        let token = try await requestRefreshToken(clientID: credential.clientID, refreshToken: refresh)
        guard !token.accessToken.isEmpty, token.refreshToken?.isEmpty == false else {
            throw TwitchSyncError.invalidAccount
        }
        var updated = credential
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken
        return updated
    }

    private func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/device")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let scope = requestedScopes.joined(separator: " ")
        let body = "client_id=\(percentEncode(clientID))&scopes=\(percentEncode(scope))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await loadAuthData(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "requesting Twitch device code", status: status, data: data)
        }

        return try TwitchAPIClient.sharedDecoder.decode(DeviceCodeResponse.self, from: data)
    }

    private func requestToken(clientID: String, deviceCode: String) async throws -> DeviceTokenResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let grantType = "urn:ietf:params:oauth:grant-type:device_code"
        let body = "client_id=\(percentEncode(clientID))&device_code=\(percentEncode(deviceCode))&grant_type=\(percentEncode(grantType))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await loadAuthData(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        if status == 400 {
            let payload = (try? TwitchAPIClient.sharedDecoder.decode(OAuthErrorPayload.self, from: data))
            switch normalizedOAuthMessage(payload?.message) {
            case "authorization_pending": throw OAuthPollingError.authorizationPending
            case "slow_down": throw OAuthPollingError.slowDown
            case "access_denied": throw OAuthPollingError.accessDenied
            case "expired_token": throw OAuthPollingError.expiredToken
            case "invalid_device_code": throw OAuthPollingError.expiredToken
            default: break
            }
        }

        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "exchanging Twitch device code", status: status, data: data)
        }

        return try TwitchAPIClient.sharedDecoder.decode(DeviceTokenResponse.self, from: data)
    }

    private func requestRefreshToken(clientID: String, refreshToken: String) async throws -> DeviceTokenResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let grantType = "refresh_token"
        let body = "client_id=\(percentEncode(clientID))&grant_type=\(percentEncode(grantType))&refresh_token=\(percentEncode(refreshToken))"
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await loadAuthData(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "refreshing Twitch token", status: status, data: data)
        }

        return try TwitchAPIClient.sharedDecoder.decode(DeviceTokenResponse.self, from: data)
    }

    private func requestValidatedIdentity(accessToken: String) async throws -> OAuthValidateResponse {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
        req.httpMethod = "GET"
        req.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await loadAuthData(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "validating Twitch token", status: status, data: data)
        }

        return try TwitchAPIClient.sharedDecoder.decode(OAuthValidateResponse.self, from: data)
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: Int

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct DeviceTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct OAuthErrorPayload: Decodable {
    let status: Int?
    let message: String
}

private struct OAuthValidateResponse: Decodable {
    let clientID: String
    let login: String
    let userID: String
    let scopes: [String]
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case login
        case userID = "user_id"
        case scopes
        case expiresIn = "expires_in"
    }
}

private enum OAuthPollingError: Error {
    case authorizationPending
    case slowDown
    case accessDenied
    case expiredToken
}

private enum TwitchAuthRefreshError: LocalizedError {
    case missingClientID
    case missingRefreshToken
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Missing Twitch client ID."
        case .missingRefreshToken:
            return "Session expired. Sign in again to reconnect Twitch."
        case .sessionExpired:
            return "Session expired. Sign in again to reconnect Twitch."
        }
    }
}
