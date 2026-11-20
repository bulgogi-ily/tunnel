import SwiftUI
import AppKit

// MARK: - Palette (macOS Terminal "Pro" profile)
let G = Color(white: 0.949)                                   // Pro text  #F2F2F2
let G2 = Color(white: 0.949).opacity(0.55)                     // dim text
let G3 = Color(white: 1).opacity(0.16)                         // hairlines
let SEL = Color(white: 0.255)                                  // Pro selection #414141
let CUR = Color(white: 0.302)                                  // Pro cursor #4D4D4D
let ANSI_GREEN = Color(red: 37/255, green: 188/255, blue: 36/255) // Pro ANSI green
let BK = Color.black

struct ProBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w, design: .monospaced) }

// MARK: - Shell
@discardableResult
func sh(_ cmd: String) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", p.terminationStatus)
}

let HOME = NSHomeDirectory()
let LABEL = "local.xray.client"
let PLIST = "\(HOME)/Library/LaunchAgents/\(LABEL).plist"
let UIDS = String(getuid())
let SOCKS = "127.0.0.1:10808"

// Read server address + camouflage SNI from the local Xray client config (never hardcoded).
let CLIENT_CONFIG: (server: String, sni: String) = {
    let path = "\(HOME)/.local/xray/config.json"
    guard let d = FileManager.default.contents(atPath: path),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let ob = (j["outbounds"] as? [[String: Any]])?.first,
          let vnext = ((ob["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first
    else { return ("not configured", "—") }
    let addr = vnext["address"] as? String ?? "?"
    let port = vnext["port"] as? Int ?? 0
    let sni = ((ob["streamSettings"] as? [String: Any])?["realitySettings"] as? [String: Any])?["serverName"] as? String ?? "—"
    return ("\(addr):\(port)", sni)
}()

// MARK: - Model
final class Tunnel: ObservableObject {
    @Published var connected = false
    @Published var busy = false
    @Published var exitIP = "—"
    @Published var tunnelMs = "—"
    @Published var directMs = "—"
    @Published var log: [String] = []
    @Published var vpn = false
    @Published var vpnInstalled = false
    private var timer: Timer?

    init() {
        say("tunnel console ready")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func say(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(s)"
        DispatchQueue.main.async {
            self.log.append(line)
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    func bg(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    func refresh() {
        bg {
            let loaded = sh("launchctl print gui/\(UIDS)/\(LABEL) >/dev/null 2>&1").code == 0
            let listening = sh("nc -z -G 1 127.0.0.1 10808").code == 0
            let inst = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/local.tunnel.vpn.plist")
            let vpnUp = sh("pgrep -f /usr/local/libexec/tunnel/sing-box").code == 0
            DispatchQueue.main.async {
                self.connected = loaded && listening
                self.vpnInstalled = inst; self.vpn = vpnUp
            }
        }
    }

    func toggle() {
        guard !busy else { return }
        busy = true
        let goingUp = !connected
        bg {
            if goingUp {
                self.say("> connecting…")
                sh("launchctl bootstrap gui/\(UIDS) '\(PLIST)'")
                var ok = false
                for _ in 0..<20 {
                    if sh("nc -z -G 1 127.0.0.1 10808").code == 0 { ok = true; break }
                    usleep(250_000)
                }
                self.say(ok ? "tunnel up on socks5://\(SOCKS)" : "ERR: tunnel did not start (see xray.log)")
                DispatchQueue.main.async { self.busy = false; self.refresh() }
                if ok { self.test() }
            } else {
                if sh("pgrep -f /usr/local/libexec/tunnel/sing-box").code == 0 {
                    self.say("> turning full VPN off first")
                    sh("sudo -n /bin/launchctl bootout system/local.tunnel.vpn")
                }
                self.say("> disconnecting…")
                sh("launchctl bootout gui/\(UIDS)/\(LABEL)")
                self.say("tunnel down")
                DispatchQueue.main.async {
                    self.busy = false; self.exitIP = "—"; self.tunnelMs = "—"; self.refresh()
                }
            }
        }
    }

    private func ttfb(_ proxy: Bool) -> String {
        let opt = proxy ? "--socks5-hostname \(SOCKS)" : "--noproxy '*'"
        var vals: [Double] = []
        for _ in 0..<4 {
            let r = sh("curl -s -o /dev/null --max-time 8 \(opt) -w '%{time_starttransfer}' https://www.google.com/generate_204")
            if let v = Double(r.out), v > 0 { vals.append(v * 1000) }
        }
        guard vals.count > 1 else { return vals.isEmpty ? "FAIL" : String(format: "%.0f ms", vals[0]) }
        let warm = Array(vals.dropFirst())
        return String(format: "%.0f ms", warm.reduce(0, +) / Double(warm.count))
    }

    func test() {
        guard !busy else { return }
        DispatchQueue.main.async { self.busy = true }
        bg {
            self.say("> testing…")
            let ip = sh("curl -s --max-time 10 --socks5-hostname \(SOCKS) https://api.ipify.org").out
            let okIP = ip.split(separator: ".").count == 4
            let t = okIP ? self.ttfb(true) : "FAIL"
            let d = self.ttfb(false)
            DispatchQueue.main.async {
                self.exitIP = okIP ? ip : "FAIL"
                self.tunnelMs = t; self.directMs = d; self.busy = false
            }
            self.say(okIP ? "exit ip \(ip) · tunnel \(t) · direct \(d)" : "ERR: no traffic through tunnel")
        }
    }

    func toggleVPN() {
        guard !busy else { return }
        guard vpnInstalled else { say("ERR: full-VPN mode not installed yet — run install-vpn.sh once"); return }
        busy = true
        let goingUp = !vpn
        bg {
            if goingUp {
                if sh("nc -z -G 1 127.0.0.1 10808").code != 0 {
                    self.say("> starting proxy first (full VPN rides on it)")
                    sh("launchctl bootstrap gui/\(UIDS) '\(PLIST)'")
                    var ok = false
                    for _ in 0..<20 { if sh("nc -z -G 1 127.0.0.1 10808").code == 0 { ok = true; break }; usleep(250_000) }
                    if !ok { self.say("ERR: proxy failed to start — not enabling VPN"); DispatchQueue.main.async { self.busy = false; self.refresh() }; return }
                }
                self.say("> full VPN on: routing ALL apps (Roblox, VNC, ssh…) through tunnel")
                let r = sh("sudo -n /bin/launchctl bootstrap system /Library/LaunchDaemons/local.tunnel.vpn.plist")
                if r.code != 0 && !r.out.isEmpty { self.say("launchctl: \(r.out)") }
                usleep(2_500_000)
            } else {
                self.say("> full VPN off")
                sh("sudo -n /bin/launchctl bootout system/local.tunnel.vpn")
                usleep(800_000)
            }
            let ip = sh("curl -s --max-time 8 --noproxy '*' https://api.ipify.org").out
            self.say("system-wide exit ip: \(ip.isEmpty ? "FAIL" : ip)")
            DispatchQueue.main.async { self.busy = false; self.refresh() }
        }
    }

    func copyProxy() {
        let s = "export ALL_PROXY=socks5h://\(SOCKS) HTTPS_PROXY=http://127.0.0.1:10809 HTTP_PROXY=http://127.0.0.1:10809"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        say("copied shell proxy exports to clipboard")
    }

    func sshServer() {
        say("> opening ssh vpn-proxied in Terminal")
        bg { sh("osascript -e 'tell application \"Terminal\" to do script \"ssh vpn-proxied\"' -e 'tell application \"Terminal\" to activate'") }
    }

    func xrayLog() {
        bg {
            let t = sh("tail -n 8 '\(HOME)/.local/xray/xray.log' 2>/dev/null").out
            if t.isEmpty { self.say("xray.log is empty — no errors") }
            else { t.split(separator: "\n").forEach { self.say("xray: \($0)") } }
        }
    }
}

// MARK: - Views
final class Flag: ObservableObject { @Published var on = false }
final class Blinker: ObservableObject {
    @Published var on = true
    private var t: Timer?
    init() { t = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in self?.on.toggle() } }
}

struct GButton: View {
    let title: String
    var primary = false
    var disabled = false
    let action: () -> Void
    @StateObject private var h = Flag()
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(mono(13, .bold))
                .foregroundColor(primary ? BK : G)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(primary ? G : (h.on ? SEL : Color.clear))
                .overlay(Rectangle().stroke(primary ? G : G2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .onHover { h.on = $0 }
    }
}

struct Row: View {
    let k: String, v: String
    var body: some View {
        HStack {
            Text(k).foregroundColor(G2)
            Spacer()
            Text(v).foregroundColor(G).textSelection(.enabled)
        }
        .font(mono(12))
    }
}

struct Blink: View {
    @StateObject private var b = Blinker()
    var body: some View {
        Text("█").foregroundColor(CUR).opacity(b.on ? 1 : 0)
    }
}

struct ContentView: View {
    @StateObject var t = Tunnel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // header
            HStack(alignment: .firstTextBaseline) {
                (Text(NSUserName() + "@mac ~ % ").foregroundColor(G2) + Text("tunnel").foregroundColor(G)).font(mono(15, .regular))
                Blink().font(mono(15))
                Spacer()
                Text("vless+reality").font(mono(11)).foregroundColor(G2)
            }

            // status
            HStack(spacing: 12) {
                Circle()
                    .fill(t.connected || t.vpn ? ANSI_GREEN : Color.clear)
                    .overlay(Circle().stroke(t.connected || t.vpn ? ANSI_GREEN : G2, lineWidth: 1.5))
                    .frame(width: 16, height: 16)
                    .shadow(color: t.connected || t.vpn ? ANSI_GREEN.opacity(0.8) : .clear, radius: 6)
                Text(t.busy ? "WORKING…" : (t.vpn ? "FULL VPN" : (t.connected ? "PROXY ON" : "DISCONNECTED")))
                    .font(mono(22, .semibold))
                    .foregroundColor(t.connected || t.vpn ? G : G2)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(Rectangle().stroke(t.connected || t.vpn ? G : G3, lineWidth: 1))

            HStack(spacing: 10) {
                GButton(title: t.connected ? "[ PROXY: ON ]" : "[ PROXY: OFF ]",
                        primary: t.connected, disabled: t.busy) { t.toggle() }
                GButton(title: t.vpn ? "[ FULL VPN: ON ]" : "[ FULL VPN: OFF ]",
                        primary: t.vpn, disabled: t.busy || !t.vpnInstalled) { t.toggleVPN() }
            }
            Text(t.vpnInstalled ? "PROXY = apps set to 127.0.0.1:10808 · FULL VPN = every app, incl. games & UDP"
                                : "FULL VPN not installed — run the one-time install command")
                .font(mono(10)).foregroundColor(G2)

            // info
            VStack(spacing: 7) {
                Row(k: "SERVER", v: CLIENT_CONFIG.server)
                Row(k: "CAMOUFLAGE", v: CLIENT_CONFIG.sni)
                Row(k: "SOCKS5", v: SOCKS)
                Row(k: "HTTP", v: "127.0.0.1:10809")
                Rectangle().fill(G3).frame(height: 1).padding(.vertical, 2)
                Row(k: "EXIT IP", v: t.exitIP)
                Row(k: "LATENCY / TUNNEL", v: t.tunnelMs)
                Row(k: "LATENCY / DIRECT", v: t.directMs)
            }
            .padding(14)
            .overlay(Rectangle().stroke(G3, lineWidth: 1))

            HStack(spacing: 10) {
                GButton(title: "TEST", disabled: t.busy || !t.connected) { t.test() }
                GButton(title: "SSH SERVER", disabled: !t.connected) { t.sshServer() }
            }
            HStack(spacing: 10) {
                GButton(title: "COPY PROXY", action: { t.copyProxy() })
                GButton(title: "XRAY LOG", action: { t.xrayLog() })
            }

            // console
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(t.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(mono(11)).foregroundColor(G2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled).id(i)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 110)
                .overlay(Rectangle().stroke(G3, lineWidth: 1))
                .onChange(of: t.log.count) {
                    withAnimation { proxy.scrollTo(t.log.count - 1, anchor: .bottom) }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 640, idealHeight: 680)
        .background(ZStack { ProBackground(); Color.black.opacity(0.72) }.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(G)
    }
}

@main
struct TunnelApp: App {
    var body: some Scene {
        WindowGroup("Tunnel") {
            ContentView()
                .onAppear {
                    for w in NSApplication.shared.windows {
                        w.backgroundColor = .clear; w.isOpaque = false
                        w.titlebarAppearsTransparent = true
                        w.titleVisibility = .hidden
                        w.isMovableByWindowBackground = true
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
