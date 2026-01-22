import SwiftUI

// MARK: - Models

enum ClimateMode: String, CaseIterable, Identifiable {
    case cool = "Cool"
    case heat = "Heat"
    case auto = "Auto"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cool: return "snowflake"
        case .heat: return "flame.fill"
        case .auto: return "arrow.triangle.2.circlepath"
        }
    }
}

struct RemoteLocation: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var icon: String

    var volume: Double        // 0...1

    var lightsOn: Bool
    var brightness: Double    // 0...1

    var climateOn: Bool
    var climateTemp: Double   // 16...28
    var climateMode: ClimateMode
}

struct BusinessStats: Equatable {
    var occupancyPercent: Int
    var transactions: Int
    var avgPerTransaction: Double
    var incomeToday: Double
}

struct ChannelBreakdown: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var icon: String
    var value: Double   // 0...1
    var subtitle: String
}

struct ChannelStats: Equatable {
    var downloads: Int
    var activeUsers: Int
}

// MARK: - Main View

struct Tesla: View {

    // Weather (mock)
    @State private var weatherTempC: Int = 18
    @State private var weatherCondition: String = "Rain"
    @State private var weatherIcon: String = "cloud.rain.fill"

    // Player (mock)
    @State private var isPlaying: Bool = true
    @State private var trackTitle: String = "Morning Espresso"
    @State private var trackArtist: String = "House Playlist"
    @State private var trackProgress: Double = 0.32 // 0...1

    // Locations (mock)
    @State private var locations: [RemoteLocation] = [
        .init(name: "Main Hall", icon: "fork.knife",
              volume: 0.65, lightsOn: true,  brightness: 0.75,
              climateOn: true, climateTemp: 22.0, climateMode: .auto),

        .init(name: "Bar", icon: "wineglass",
              volume: 0.50, lightsOn: true,  brightness: 0.60,
              climateOn: true, climateTemp: 21.0, climateMode: .cool),

        .init(name: "Terrace", icon: "leaf",
              volume: 0.40, lightsOn: false, brightness: 0.35,
              climateOn: false, climateTemp: 24.0, climateMode: .heat),

        .init(name: "Kitchen", icon: "flame",
              volume: 0.15, lightsOn: true,  brightness: 0.80,
              climateOn: true, climateTemp: 19.0, climateMode: .cool),

        .init(name: "Entrance", icon: "door.left.hand.open",
              volume: 0.30, lightsOn: true, brightness: 0.55,
              climateOn: true, climateTemp: 21.0, climateMode: .auto),
    ]

    // Mood presets (mock)
    @State private var selectedMood: String? = "Chill"
    private let moods: [(title: String, icon: String)] = [
        ("Chill", "sparkles"),
        ("Lunch Rush", "bolt.fill"),
        ("Romantic", "heart.fill"),
        ("Party", "music.note.list"),
        ("Closing", "moon.stars.fill")
    ]

    // Business Stats (mock)
    @State private var stats = BusinessStats(
        occupancyPercent: 72,
        transactions: 184,
        avgPerTransaction: 54.8,
        incomeToday: 10340
    )

    // Channels (mock)
    @State private var channels: [ChannelBreakdown] = [
        .init(title: "Cashpoint (Self)",  icon: "rectangle.and.hand.point.up.left.fill", value: 0.42, subtitle: "QR / kiosk"),
        .init(title: "Cashpoint (Staff)", icon: "person.badge.key.fill", value: 0.28, subtitle: "staff POS"),
        .init(title: "MiniApp",           icon: "bolt.fill", value: 0.19, subtitle: "app clip / instant"),
        .init(title: "App",               icon: "app.fill", value: 0.11, subtitle: "native users")
    ]
    @State private var channelStats = ChannelStats(downloads: 1840, activeUsers: 312)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    weatherCard
                    channelsCard
                    statsGrid
                    moodCard
                    nowPlayingCard
                    volumeCard
                    lightsCard
                    climateCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Beit Haam")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Cards

    private var weatherCard: some View {
        HStack(spacing: 14) {
            Image(systemName: weatherIcon)
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 4) {
                Text(weatherCondition).font(.headline)
                Text("Outside now").font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(weatherTempC)°")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .cardStyle()
    }

    private var channelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow(title: "Channels", icon: "arrow.left.arrow.right.circle.fill")

            VStack(spacing: 12) {
                ForEach(channels) { ch in
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: ch.icon)
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(ch.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("\(Int(ch.value * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        ProgressView(value: ch.value)
                            .tint(.blue)
                    }
                }
            }

            Divider().opacity(0.6)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                statBox(title: "Downloads", value: formatInt(channelStats.downloads), icon: "arrow.down.app.fill")
                statBox(title: "Active App Users", value: formatInt(channelStats.activeUsers), icon: "person.2.fill")
            }
        }
        .cardStyle()
    }

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow(title: "Performence", icon: "chart.bar.fill")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                statBox(title: "Occupancy", value: "\(stats.occupancyPercent)%", icon: "person.2.fill")
                statBox(title: "Transactions", value: "\(stats.transactions)", icon: "creditcard.fill")
                statBox(title: "Avg / Txn", value: money(stats.avgPerTransaction), icon: "tag.fill")
                statBox(title: "Income", value: money(stats.incomeToday), icon: "sterlingsign.circle.fill")
            }
        }
        .cardStyle()
    }

    private var moodCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow(title: "Mood Presets", icon: "slider.horizontal.3")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(moods, id: \.title) { mood in
                    Button { selectedMood = mood.title } label: {
                        HStack(spacing: 10) {
                            Image(systemName: mood.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(mood.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if selectedMood == mood.title {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selectedMood == mood.title ? Color.pillSelectedFill : Color.pillFill)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .cardStyle()
    }

    private var nowPlayingCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.pillSelectedFill)
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(trackTitle).font(.headline).lineLimit(1)
                    Text(trackArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                HStack(spacing: 14) {
                    Button { } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }

                    Button { isPlaying.toggle() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(Color.pillSelectedFill)
                            .clipShape(Circle())
                    }

                    Button { } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 6) {
                ProgressView(value: trackProgress)
                    .tint(.blue)
                HStack {
                    Text(timeString(trackProgress * 180))
                    Spacer()
                    Text(timeString(180))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .cardStyle()
    }

    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow(title: "Audio by Location", icon: "speaker.wave.2.fill")

            VStack(spacing: 10) {
                ForEach(locations.indices, id: \.self) { i in
                    let loc = locations[i]
                    HStack(spacing: 12) {
                        Image(systemName: loc.icon).frame(width: 22)
                        Text(loc.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Slider(value: $locations[i].volume, in: 0...1)
                            .frame(maxWidth: 170)
                        Text("\(Int(locations[i].volume * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                }
            }
            .tint(.blue)
        }
        .cardStyle()
    }

    private var lightsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow(title: "Lights", icon: "lightbulb.fill")

            VStack(spacing: 10) {
                ForEach(locations.indices, id: \.self) { i in
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: locations[i].icon).frame(width: 22)
                            Text(locations[i].name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Toggle("", isOn: $locations[i].lightsOn).labelsHidden()
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)

                            Slider(value: $locations[i].brightness, in: 0...1)
                                .disabled(!locations[i].lightsOn)

                            Text("\(Int(locations[i].brightness * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .opacity(locations[i].lightsOn ? 1 : 0.45)
                    }
                    .padding(.vertical, 8)
                    .tint(.blue)

                    if i != locations.indices.last {
                        Divider().opacity(0.6)
                    }
                }
            }
        }
        .cardStyle()
    }

    private var climateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow(title: "Climate", icon: "thermometer")

            VStack(spacing: 12) {
                ForEach(locations.indices, id: \.self) { i in
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: locations[i].icon).frame(width: 22)
                            Text(locations[i].name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Toggle("", isOn: $locations[i].climateOn).labelsHidden()
                        }

                        HStack(spacing: 10) {
                            ForEach(ClimateMode.allCases) { mode in
                                Button {
                                    locations[i].climateMode = mode
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: mode.icon)
                                        Text(mode.rawValue)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(locations[i].climateMode == mode ? Color.pillSelectedFill : Color.pillFill)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!locations[i].climateOn)
                                .opacity(locations[i].climateOn ? 1 : 0.45)
                            }
                          
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "thermometer.medium")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)

                            Slider(value: $locations[i].climateTemp, in: 16...28, step: 0.5)
                                .disabled(!locations[i].climateOn)

                            Text("\(locations[i].climateTemp, specifier: "%.1f")°")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 54, alignment: .trailing)
                        }
                        
                        .opacity(locations[i].climateOn ? 1 : 0.45)
                    }
                    .tint(.blue)
                    if i != locations.indices.last {
                        Divider().opacity(0.6)
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Components

    private func headerRow(title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).symbolRenderingMode(.hierarchical)
            Text(title).font(.headline)
            Spacer()
        }
    }

    private func statBox(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).symbolRenderingMode(.hierarchical)
                Spacer()
            }

            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "ILS"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func formatInt(_ v: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

// MARK: - View helpers

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
    }
}

private extension Color {
    static var pillFill: Color { Color(uiColor: .tertiarySystemFill) }
    static var pillSelectedFill: Color { Color(uiColor: .secondarySystemFill) }
}

#Preview {
    Tesla()
}
