import AppKit

@main struct PopoverChecks {
 @MainActor static func main() {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  var checks = 0
  func require(_ yes:Bool,_ message:String) {
   if !yes { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) };checks += 1
  }
  let anchorWindow = NSWindow(contentRect:NSRect(x:100,y:100,width:180,height:80),styleMask:[.borderless],backing:.buffered,defer:false)
  anchorWindow.alphaValue = 0
  let anchor = NSButton(frame:NSRect(x:20,y:20,width:60,height:24))
  anchorWindow.contentView!.addSubview(anchor)
  anchorWindow.orderFront(nil)
  let popover = NSPopover()
  popover.animates = false
  // Unit checks explicitly disable AppKit's transient fallback so the added
  // dismissal lifecycle is exercised on its own with fake AppKit windows.
  popover.behavior = .applicationDefined
  let content = NSViewController();content.view=NSView(frame:NSRect(x:0,y:0,width:100,height:80))
  popover.contentViewController=content
  let dismissal=PopoverDismissalController()
  dismissal.attach(to:popover,anchor:anchor)
  func show() {
   popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
   popover.contentViewController?.view.window?.alphaValue=0
   require(popover.isShown,"fictional popover is actually shown")
  }
  show()
  let panel = content.view.window!
  dismissal.handleLocalClick(in:panel,location:NSPoint(x:30,y:30))
  require(popover.isShown,"inside clicks keep the panel open")
  dismissal.handleLocalClick(in:anchorWindow,location:NSPoint(x:30,y:25))
  require(popover.isShown,"status-button clicks are left to the toggle action")
  let child=NSWindow(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
  child.alphaValue=0
  panel.addChildWindow(child,ordered:.above)
  dismissal.handleLocalClick(in:child)
  require(popover.isShown,"owned help popovers remain interactive")
  dismissal.handleLocalClick(in:anchorWindow,location:NSPoint(x:150,y:50))
  RunLoop.main.run(until:Date().addingTimeInterval(0.05))
  require(!popover.isShown,"outside the anchor, a click in the same application closes the panel")
  show()
  let other=NSWindow(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
  dismissal.handleLocalClick(in:other)
  RunLoop.main.run(until:Date().addingTimeInterval(0.05))
  require(!popover.isShown,"an unrelated window closes the panel")
  for _ in 0..<3 {
   show()
   NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:NSApp)
   RunLoop.main.run(until:Date().addingTimeInterval(0.05))
  require(!popover.isShown,"deactivation dismisses the panel after every reopen")
  }
  panel.removeChildWindow(child)
  dismissal.stopMonitoring()
  anchorWindow.orderOut(nil)
  print("PASS \(checks) fictional AppKit popover lifecycle checks; no real account or service accessed")
 }
}
