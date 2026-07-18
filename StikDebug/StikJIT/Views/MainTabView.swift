

import SwiftUI

struct MainTabView: View {
    @State private var selection: AppSection = .simulator
    @State private var showWelcome = true
    @State private var isDismissingWelcome = false

    private enum AppSection: Hashable {
        case simulator
        case settings
    }
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.1, blue: 0.2), Color(red: 0.04, green: 0.24, blue: 0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            TabView(selection: $selection) {
                NavigationStack {
                    LocationSimulationView()
                }
                .tabItem { Label("Simulator", systemImage: "location.viewfinder") }
                .tag(AppSection.simulator)

                NavigationStack {
                    SimulationSettingsView()
                }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(AppSection.settings)
            }
            .tint(Color(red: 0.41, green: 0.93, blue: 0.78))

            // Welcome overlay
            if showWelcome {
                WelcomeOverlay(isDismissing: isDismissingWelcome) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isDismissingWelcome = true
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        withAnimation(.easeOut(duration: 0.35)) {
                            showWelcome = false
                        }
                        isDismissingWelcome = false
                    }
                }
                .transition(.opacity)
            }
        }
    }

}

// MARK: - Welcome Overlay

private struct WelcomeOverlay: View {
    let isDismissing: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Blurred background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // App icon / logo area
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.41, green: 0.93, blue: 0.78), Color(red: 0.12, green: 0.62, blue: 0.90)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 90, height: 90)

                    Image(systemName: "location.fill.viewfinder")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }

                // Title
                Text("GhostPin")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // Description
                VStack(spacing: 14) {
                    WelcomeRow(icon: "mappin.and.ellipse", text: "Tap anywhere on the map to drop a pin at your desired location")
                    WelcomeRow(icon: "play.fill", text: "Hit Simulate to spoof your GPS — works across all apps instantly")
                    WelcomeRow(icon: "point.topleft.down.to.point.bottomright.curvepath", text: "Create routes with multiple stops for automated movement")
                    WelcomeRow(icon: "bookmark.fill", text: "Save your favourite locations as bookmarks for quick access")
                    WelcomeRow(icon: "wifi", text: "Connect LocalDevVPN before simulating. On cellular, start LocalDevVPN, enable Airplane Mode, then turn cellular back on")
                }
                .padding(.horizontal, 24)

                Spacer()

                // Start button
                Button(action: onDismiss) {
                    Text("Get Started")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.05, green: 0.1, blue: 0.2))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.41, green: 0.93, blue: 0.78), Color(red: 0.30, green: 0.85, blue: 0.90)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .padding(.horizontal, 32)

                // Credit
                Text("Re-designed & modified by HaX0r 🦄")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.bottom, 24)
            }
            .scaleEffect(isDismissing ? 0.96 : 1.0)
            .offset(y: isDismissing ? 14 : 0)
            .opacity(isDismissing ? 0 : 1)
            .blur(radius: isDismissing ? 1.5 : 0)
            .animation(.easeInOut(duration: 0.25), value: isDismissing)
        }
    }
}

private struct WelcomeRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(red: 0.41, green: 0.93, blue: 0.78))
                .frame(width: 28)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
