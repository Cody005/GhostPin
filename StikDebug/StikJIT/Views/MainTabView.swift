

import SwiftUI

struct MainTabView: View {
    @State private var selection: AppSection = .simulator

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
        }
    }

}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
