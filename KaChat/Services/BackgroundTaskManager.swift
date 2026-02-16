import Foundation
import BackgroundTasks
import UserNotifications

/// Manages background fetch tasks for checking new messages when app is in background
@MainActor
final class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()

    /// Background task identifier - must match Info.plist entry
    static let backgroundFetchTaskIdentifier = "com.kachat.app.messageFetch"

    /// Requested refresh interval (iOS may adjust based on battery/usage patterns)
    private let refreshInterval: TimeInterval = 60

    private init() {}

    /// Register the background task handler - call once at app launch
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundFetchTaskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                await self.handleBackgroundFetch(task: task as! BGAppRefreshTask)
            }
        }
        print("[BackgroundTaskManager] Registered background fetch task")
    }

    /// Schedule the next background fetch - call when app goes to background
    func scheduleBackgroundFetch() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundFetchTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundTaskManager] Scheduled background fetch for ~\(Int(refreshInterval))s from now")
        } catch {
            print("[BackgroundTaskManager] Failed to schedule background fetch: \(error.localizedDescription)")
        }
    }

    /// Cancel any pending background fetch tasks
    func cancelBackgroundFetch() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundFetchTaskIdentifier)
        print("[BackgroundTaskManager] Cancelled background fetch")
    }

    /// Handle the background fetch task
    private func handleBackgroundFetch(task: BGAppRefreshTask) async {
        print("[BackgroundTaskManager] Background fetch started")

        // Schedule the next fetch before doing work
        scheduleBackgroundFetch()

        // Set up expiration handler
        task.expirationHandler = {
            print("[BackgroundTaskManager] Background fetch expired")
            task.setTaskCompleted(success: false)
        }

        // Check if background fetch is enabled in settings
        guard ChatService.shared.settingsViewModel?.settings.backgroundFetchEnabled == true else {
            print("[BackgroundTaskManager] Background fetch disabled, skipping fetch")
            task.setTaskCompleted(success: true)
            return
        }

        // Fetch new messages
        await ChatService.shared.fetchNewMessages()
        print("[BackgroundTaskManager] Background fetch completed successfully")
        task.setTaskCompleted(success: true)
    }
}
