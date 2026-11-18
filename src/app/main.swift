// main.swift — Battery Commander (BC) standalone app, Stage A (bench).
//
// Entry point. Two modes:
//   (no args)      run the menu-bar app (LSUIElement; no Dock icon).
//   --dump-menu    collect one live snapshot, print the canonical menu
//                  dump (title + item tree with checkmarks, actions,
//                  colours), and exit — the machine-verifiable parity
//                  surface used by the Stage A smoke tests.

import AppKit
import Foundation

let args = CommandLine.arguments

if args.contains("--dump-menu") {
    let snap = StatusProvider.collect()
    let nodes = MenuModel.build(from: snap)
    print(MenuModel.dump(title: snap.titleText, color: snap.finalColor, nodes: nodes),
          terminator: "")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
