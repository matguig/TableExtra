// Sends automation commands to a running TableExtra started with MTP_AUTOMATION=1.
// Usage: mtpctl "snapshot:/tmp/a.png" ["table:public.orders" ...]  (each command waits 0.8 s)
// Set MTP_AUTOMATION_ID to target the app instance started with the same value.
import Foundation

let suffix = ProcessInfo.processInfo.environment["MTP_AUTOMATION_ID"].map { "." + $0 } ?? ""

for command in CommandLine.arguments.dropFirst() {
    if command.hasPrefix("sleep:"), let s = Double(command.dropFirst(6)) {
        Thread.sleep(forTimeInterval: s)
        continue
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("fr.koa-dev.TableExtra.automation" + suffix), object: command, userInfo: nil, deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.8)
}
