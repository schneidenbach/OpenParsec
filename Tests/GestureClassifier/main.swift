// Off-device tests for TouchGestureClassifier. Run with Tests/GestureClassifier/run.sh.
import CoreGraphics
import Foundation

// SettingsHandler.swift (which defines this) depends on SwiftUI; mirror it here.
enum PointerAcceleration { case linear, adaptive, fast }

typealias C = TouchGestureClassifier
var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) { if !cond { failures += 1; print("FAIL L\(line): \(msg)") } }
func s(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> C.TouchSample { .init(id: id, location: CGPoint(x: x, y: y)) }
func cfg(_ mode: C.PointerMode = .trackpad, dtd: Bool = true, lock: Bool = false, zoomed: Bool = false, anchor: C.RightClickAnchor = .firstFinger, momentum: Bool = false) -> C.Configuration {
	var c = C.Configuration(); c.mode = mode; c.doubleTapToDrag = dtd; c.dragLock = lock; c.viewportPannable = zoomed; c.rightClickAnchor = anchor; c.interruptsMomentum = momentum; return c
}
func moves(_ o: [C.Output]) -> Bool { o.contains { if case .movePointer = $0 { return true }; if case .movePointerTo = $0 { return true }; return false } }
func clicks(_ o: [C.Output]) -> Bool { o.contains { if case .click = $0 { return true }; return false } }

// Trackpad tap with jitter: no movement, click at cursor, immediately on lift.
do {
	let g = C(); var out: [C.Output] = []
	out += g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	out += g.touchesMoved([s(1, 104, 97)], at: 0.03)
	out += g.touchesMoved([s(1, 107, 102)], at: 0.06)
	check(!moves(out), "jitter must not move pointer: \(out)")
	let up = g.touchesEnded([1], at: 0.09)
	check(up == [.click(.left, at: nil)], "trackpad tap clicks at cursor: \(up)")
}
// Trackpad double-tap = two clicks at cursor, no movement.
do {
	let g = C(); var out: [C.Output] = []
	out += g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	out += g.touchesEnded([1], at: 0.08)
	out += g.touchesBegan([s(2, 110, 104)], at: 0.2, configuration: cfg())
	out += g.touchesEnded([2], at: 0.28)
	check(out == [.click(.left, at: nil), .click(.left, at: nil)], "double tap: \(out)")
}
// Trackpad move: catch-up unaccelerated, then accelerated deltas, no click.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	let a = g.touchesMoved([s(1, 112, 100)], at: 0.05)
	check(a == [.movePointer(dx: 12, dy: 0, dt: 0.05, accelerate: false)], "catch-up: \(a)")
	let b = g.touchesMoved([s(1, 120, 100)], at: 0.06)
	if case .movePointer(let dx, _, let dt, let acc)? = b.first { check(dx == 8 && acc && abs(dt - 0.01) < 1e-9, "delta \(b)") } else { check(false, "no move \(b)") }
	check(g.touchesEnded([1], at: 0.1).isEmpty, "move then lift: no click")
}
// Trackpad hold: arms, lift without moving = click; hold + move = press, drag, release.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	check(g.holdDeadline == C.Tuning.holdDuration, "hold deadline")
	check(g.holdTimerFired(at: 0.45) == [.feedback(.grab)], "hold arms")
	check(!g.isButtonHeld, "armed not pressed")
	check(g.touchesMoved([s(1, 103, 100)], at: 0.5).isEmpty, "jitter after hold ignored")
	check(g.touchesEnded([1], at: 0.6) == [.click(.left, at: nil)], "long click")

	let h = C()
	_ = h.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	_ = h.holdTimerFired(at: 0.45)
	let m = h.touchesMoved([s(1, 100, 115)], at: 0.5)
	check(m.first == .press(.left) && moves(m), "drag starts: \(m)")
	check(h.isButtonHeld, "held")
	let e = h.touchesEnded([1], at: 0.7)
	check(e == [.release(.left), .feedback(.release)], "drag release \(e)")
	check(!h.isButtonHeld, "released")
}
// Tap then touch-and-drag (doubleTapToDrag) → click, then press+drag+release.
do {
	let g = C(); var out: [C.Output] = []
	out += g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	out += g.touchesEnded([1], at: 0.08)
	out += g.touchesBegan([s(2, 102, 100)], at: 0.2, configuration: cfg())
	let m = g.touchesMoved([s(2, 130, 100)], at: 0.25)
	check(m.first == .press(.left), "tap-drag press: \(m)")
	check(g.touchesEnded([2], at: 0.4).first == .release(.left), "tap-drag release")
	// With the setting off, it's a pointer move.
	let h = C()
	_ = h.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg(dtd: false)); _ = h.touchesEnded([1], at: 0.08)
	_ = h.touchesBegan([s(2, 102, 100)], at: 0.2, configuration: cfg(dtd: false))
	let hm = h.touchesMoved([s(2, 130, 100)], at: 0.25)
	if case .movePointer(28, 0, _, false)? = hm.first, hm.count == 1 {} else { check(false, "no tap-drag when disabled \(hm)") }
	// A far-away touch after a tap is a plain move.
	let k = C()
	_ = k.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg()); _ = k.touchesEnded([1], at: 0.08)
	_ = k.touchesBegan([s(2, 300, 300)], at: 0.2, configuration: cfg())
	check(k.touchesMoved([s(2, 330, 300)], at: 0.25).first != .press(.left), "far touch is not tap-drag")
}
// Drag lock: drag lift keeps button; next move drags; tap releases without click.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg(lock: true))
	_ = g.holdTimerFired(at: 0.45)
	_ = g.touchesMoved([s(1, 130, 100)], at: 0.5)
	check(g.touchesEnded([1], at: 0.6).isEmpty, "locked: no release")
	check(g.isButtonHeld, "lock holds")
	_ = g.touchesBegan([s(2, 100, 100)], at: 1.0, configuration: cfg(lock: true))
	let m = g.touchesMoved([s(2, 120, 100)], at: 1.05)
	check(m.count == 1 && moves(m), "locked move, no extra press: \(m)")
	check(g.touchesEnded([2], at: 1.1).isEmpty, "still locked")
	// Two-finger scroll keeps the lock.
	_ = g.touchesBegan([s(3, 100, 100), s(4, 150, 100)], at: 2, configuration: cfg(lock: true))
	_ = g.touchesMoved([s(3, 100, 130), s(4, 150, 130)], at: 2.05)
	_ = g.touchesEnded([3, 4], at: 2.1)
	check(g.isButtonHeld, "scroll keeps lock")
	_ = g.touchesBegan([s(5, 100, 100)], at: 3, configuration: cfg(lock: true))
	check(g.touchesEnded([5], at: 3.05) == [.release(.left), .feedback(.release)], "tap releases lock")
	check(!g.isButtonHeld, "unlocked")
	// Held without moving never locks.
	let h = C()
	_ = h.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg(lock: true)); _ = h.holdTimerFired(at: 0.45)
	check(h.touchesEnded([1], at: 0.6) == [.click(.left, at: nil)] && !h.isButtonHeld, "long click doesn't lock")
}
// Direct tap: click under finger (start point); double-tap stays on one spot.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 200, 150)], at: 0, configuration: cfg(.direct))
	check(g.holdDeadline == nil, "no hold in direct")
	_ = g.touchesMoved([s(1, 205, 152)], at: 0.04)
	check(g.touchesEnded([1], at: 0.07) == [.click(.left, at: CGPoint(x: 200, y: 150))], "direct tap at finger")
	_ = g.touchesBegan([s(2, 206, 147)], at: 0.2, configuration: cfg(.direct))
	check(g.touchesEnded([2], at: 0.26) == [.click(.left, at: CGPoint(x: 200, y: 150))], "second click same spot")
}
// Direct drag: move to start, press, track finger, release.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 200, 150)], at: 0, configuration: cfg(.direct))
	let m = g.touchesMoved([s(1, 220, 150)], at: 0.05)
	check(m == [.movePointerTo(CGPoint(x: 200, y: 150)), .press(.left), .movePointerTo(CGPoint(x: 220, y: 150))], "direct drag start \(m)")
	check(g.touchesMoved([s(1, 240, 160)], at: 0.07) == [.movePointerTo(CGPoint(x: 240, y: 160))], "direct follow")
	check(g.touchesEnded([1], at: 0.1) == [.release(.left), .feedback(.release)], "direct release")
}
// Two-finger tap = right click; staggered lift still counts; slow one does not.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	_ = g.touchesBegan([s(2, 160, 100)], at: 0.03, configuration: cfg())
	check(g.touchesEnded([1], at: 0.1).isEmpty, "first lift waits")
	check(g.touchesEnded([2], at: 0.13) == [.click(.right, at: nil)], "right click")
	let d = C()
	_ = d.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg(.direct, anchor: .secondFinger))
	check(d.touchesEnded([1, 2], at: 0.1) == [.click(.right, at: CGPoint(x: 160, y: 100))], "direct right click anchor")
	let l = C()
	_ = l.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg())
	check(l.touchesEnded([1, 2], at: 0.6).isEmpty, "slow two-finger rest: nothing")
	// Second finger before the hold fires cancels the hold.
	let x = C()
	_ = x.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	_ = x.touchesBegan([s(2, 160, 100)], at: 0.1, configuration: cfg())
	check(x.holdDeadline == nil, "hold cancelled")
	check(x.holdTimerFired(at: 0.45).isEmpty, "no hold with two fingers")
}
// Two-finger scroll is exclusive: lock pinch, no click, momentum on lift; staggered lift keeps fling.
do {
	let g = C(); var out: [C.Output] = []
	out += g.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg())
	out += g.touchesMoved([s(1, 100, 106), s(2, 160, 106)], at: 0.02)
	check(out.isEmpty, "below scroll slop: \(out)")
	let start = g.touchesMoved([s(1, 100, 112), s(2, 160, 112)], at: 0.04)
	check(start == [.lockViewport(true)], "scroll classified: \(start)")
	let sc = g.touchesMoved([s(1, 100, 124), s(2, 160, 124)], at: 0.05)
	check(sc == [.scroll(dx: 0, dy: 12)], "scroll delta \(sc)")
	_ = g.touchesMoved([s(1, 100, 136), s(2, 160, 136)], at: 0.06)
	check(g.touchesEnded([1], at: 0.065).isEmpty, "first lift")
	check(g.touchesMoved([s(2, 160, 160)], at: 0.07).isEmpty, "no jump after partial lift")
	let end = g.touchesEnded([2], at: 0.08)
	if case .scrollEnded(_, let vy)? = end.first { check(vy > 500, "fling kept: \(vy)") } else { check(false, "no scrollEnded \(end)") }
	check(end.last == .lockViewport(false), "unlock \(end)")
	check(!moves(out + start + sc + end), "scroll never moves pointer")
}
// Pinch: spread change → viewport, no scroll, no right click.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg())
	let p = g.touchesMoved([s(1, 80, 100), s(2, 180, 100)], at: 0.05)
	check(p.isEmpty, "pinch emits nothing \(p)")
	check(g.touchesMoved([s(1, 80, 160), s(2, 180, 160)], at: 0.1).isEmpty, "no scroll after pinch")
	check(g.touchesEnded([1, 2], at: 0.15).isEmpty, "no right click after pinch")
	// UIScrollView pinch began → viewport.
	let u = C()
	_ = u.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg())
	u.viewportGestureBegan()
	check(u.touchesMoved([s(1, 100, 130), s(2, 160, 130)], at: 0.05).isEmpty, "no scroll during zoom")
	check(u.touchesEnded([1, 2], at: 0.1).isEmpty, "no click after zoom")
}
// Zoomed in: two fingers still scroll the host, pinch still zooms, two-finger tap right-clicks.
do {
	let z = C()
	_ = z.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg(zoomed: true))
	check(z.touchesMoved([s(1, 100, 112), s(2, 160, 112)], at: 0.05) == [.lockViewport(true)], "zoomed two-finger drag scrolls host")
	check(z.touchesMoved([s(1, 100, 130), s(2, 160, 130)], at: 0.06) == [.scroll(dx: 0, dy: 18)], "zoomed scroll delta")
	let ze = z.touchesEnded([1, 2], at: 0.07)
	check(ze.contains(.lockViewport(false)) && !clicks(ze), "zoomed scroll end \(ze)")
	let zp = C()
	_ = zp.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg(zoomed: true))
	check(zp.touchesMoved([s(1, 80, 100), s(2, 180, 100)], at: 0.05).isEmpty, "zoomed pinch local")
	check(zp.touchesMoved([s(1, 80, 140), s(2, 180, 140)], at: 0.1).isEmpty, "no scroll after zoomed pinch")
	let zt = C()
	_ = zt.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg(zoomed: true))
	check(zt.touchesEnded([1, 2], at: 0.1) == [.click(.right, at: nil)], "zoomed two-finger tap still right-clicks")
}
// Three fingers: tap → keyboard; vertical → scroll; horizontal → one display swipe; zoomed → local pan.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 100, 100), s(2, 150, 100), s(3, 200, 100)], at: 0, configuration: cfg())
	check(g.touchesEnded([1, 2, 3], at: 0.1) == [.showKeyboard], "3 tap")
	let v = C()
	_ = v.touchesBegan([s(1, 100, 100), s(2, 150, 100), s(3, 200, 100)], at: 0, configuration: cfg())
	check(v.touchesMoved([s(1, 100, 120), s(2, 150, 120), s(3, 200, 120)], at: 0.05) == [.lockViewport(true)], "3 scroll")
	check(v.touchesMoved([s(1, 100, 130), s(2, 150, 130), s(3, 200, 130)], at: 0.06) == [.scroll(dx: 0, dy: 10)], "3 scroll delta")
	let h = C(); var out: [C.Output] = []
	_ = h.touchesBegan([s(1, 100, 100), s(2, 150, 100), s(3, 200, 100)], at: 0, configuration: cfg())
	out += h.touchesMoved([s(1, 80, 100), s(2, 130, 100), s(3, 180, 100)], at: 0.03)
	out += h.touchesMoved([s(1, 30, 102), s(2, 80, 102), s(3, 130, 102)], at: 0.06)
	out += h.touchesMoved([s(1, -30, 102), s(2, 20, 102), s(3, 70, 102)], at: 0.09)
	out += h.touchesEnded([1, 2, 3], at: 0.12)
	check(out == [.cycleDisplay(1)], "single left swipe \(out)")
	let vp = C()
	_ = vp.touchesBegan([s(1, 100, 100), s(2, 150, 100), s(3, 200, 100)], at: 0, configuration: cfg(zoomed: true))
	check(vp.touchesMoved([s(1, 80, 100), s(2, 130, 100), s(3, 180, 100)], at: 0.05) == [.lockViewport(true), .panViewport(dx: -20, dy: 0)], "zoomed 3 pan start")
	check(vp.touchesMoved([s(1, 0, 100), s(2, 50, 100), s(3, 100, 100)], at: 0.08) == [.panViewport(dx: -80, dy: 0)], "zoomed 3 pan, no swipe")
	check(vp.touchesEnded([1], at: 0.1).isEmpty, "partial lift")
	check(vp.touchesMoved([s(2, 0, 300), s(3, 50, 300)], at: 0.12).isEmpty, "no jump after lift")
	check(vp.touchesEnded([2, 3], at: 0.14) == [.lockViewport(false)], "pan end unlocks")
	let vt = C()
	_ = vt.touchesBegan([s(1, 100, 100), s(2, 150, 100), s(3, 200, 100)], at: 0, configuration: cfg(zoomed: true))
	check(vt.touchesEnded([1, 2, 3], at: 0.1) == [.showKeyboard], "zoomed 3 tap still keyboard")
}
// Pointer move, then second finger → scroll, never a click; drag + second finger releases.
do {
	let g = C(); var out: [C.Output] = []
	_ = g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg())
	_ = g.touchesMoved([s(1, 130, 100)], at: 0.05)
	out += g.touchesBegan([s(2, 190, 100)], at: 0.1, configuration: cfg())
	out += g.touchesMoved([s(1, 130, 120), s(2, 190, 120)], at: 0.15)
	out += g.touchesEnded([1, 2], at: 0.2)
	check(!clicks(out), "no click \(out)")
	check(out.contains(.lockViewport(true)), "became scroll \(out)")
	let d = C()
	_ = d.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg(.direct))
	_ = d.touchesMoved([s(1, 130, 100)], at: 0.05)
	check(d.touchesBegan([s(2, 190, 100)], at: 0.1, configuration: cfg(.direct)) == [.release(.left), .feedback(.release)], "drag aborted by 2nd finger")
	check(d.touchesEnded([1, 2], at: 0.2).isEmpty, "nothing after abort")
}
// Momentum-stopping touch doesn't click; cancellation releases; reset releases lock.
do {
	let g = C()
	_ = g.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg(momentum: true))
	check(g.touchesEnded([1], at: 0.05).isEmpty, "momentum-stop tap doesn't click")
	let c = C()
	_ = c.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg(.direct))
	_ = c.touchesMoved([s(1, 130, 100)], at: 0.05)
	check(c.touchesCancelled([1], at: 0.1) == [.release(.left), .feedback(.release)] && !c.isButtonHeld, "cancel releases")
	let r = C()
	_ = r.touchesBegan([s(1, 100, 100)], at: 0, configuration: cfg(lock: true)); _ = r.holdTimerFired(at: 0.45)
	_ = r.touchesMoved([s(1, 130, 100)], at: 0.5); _ = r.touchesEnded([1], at: 0.6)
	check(r.reset() == [.release(.left)] && !r.isButtonHeld, "reset releases lock")
	let v = C()
	_ = v.touchesBegan([s(1, 100, 100), s(2, 160, 100)], at: 0, configuration: cfg())
	_ = v.touchesMoved([s(1, 100, 120), s(2, 160, 120)], at: 0.05)
	check(v.touchesCancelled([1, 2], at: 0.1) == [.lockViewport(false)], "cancel unlocks")
}
// Acceleration: slow = 1:1 (adaptive), fast amplified, direction preserved, rate independent.
do {
	var a = PointerAccelerator(curve: .adaptive)
	let slow = a.scale(dx: 1, dy: 0.5, dt: 1.0 / 120, accelerate: true)
	check(slow.dx == 1 && slow.dy == 0.5, "slow 1:1 \(slow)")
	a.reset()
	let fast = a.scale(dx: 12, dy: 9, dt: 1.0 / 120, accelerate: true)
	check(fast.dx > 12 && abs(fast.dy / fast.dx - 0.75) < 1e-9, "fast amplified, direction kept \(fast)")
	var b = PointerAccelerator(curve: .adaptive); var c = PointerAccelerator(curve: .adaptive)
	var sum60: CGFloat = 0, sum120: CGFloat = 0
	for _ in 0..<60 { sum60 += b.scale(dx: 10, dy: 0, dt: 1.0 / 60, accelerate: true).dx }
	for _ in 0..<120 { sum120 += c.scale(dx: 5, dy: 0, dt: 1.0 / 120, accelerate: true).dx }
	check(abs(sum60 - sum120) < 1, "sample-rate independent \(sum60) \(sum120)")
	check(PointerAccelerator.gain(for: 5000, curve: .adaptive) == 2.2 && PointerAccelerator.gain(for: 5000, curve: .fast) == 3.2, "caps")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
