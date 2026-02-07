import SwiftUI

struct AppleHomeStyleRestaurantMap: View {

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar

                // MAP
                map
                    .frame(height: 360)
                    .padding(.top, 6)

                // CONTROLS
                controlRow
                    .padding(.top, 12)

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    private var background: some View {
        Color(red: 0.13, green: 0.13, blue: 0.14)
            .ignoresSafeArea()
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Beit Haam")
                        .font(.system(size: 22, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }

                Text("Occupied • 71%")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            HStack(spacing: 16) {
                topIcon("bubble.left")
                topIcon("line.3.horizontal")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func topIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(.white.opacity(0.85))
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    // MARK: - Map (4 tables per row)

    private var map: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            // 4 columns
            let c1 = w * 0.18
            let c2 = w * 0.38
            let c3 = w * 0.58
            let c4 = w * 0.78
            
            // 2 rows
            let r1 = h * 0.45
            let r2 = h * 0.74
            
            ZStack {
                VStack {
                    bar
                        .frame(width: w * 0.72, height: 56)
                    Spacer()
                }
                .padding(.top, h * 0.12)
                
                // ROW 1
                table(.active, seed: 1).position(x: c1, y: r1)
                table(.inactive, seed: 2).position(x: c2, y: r1)
                table(.active, seed: 3).position(x: c3, y: r1)
                table(.inactive, seed: 4).position(x: c4, y: r1)
                
                // ROW 2
                table(.inactive, seed: 5).position(x: c1, y: r2)
                table(.active, seed: 6).position(x: c2, y: r2)
                table(.active, seed: 7).position(x: c3, y: r2)
                table(.active, seed: 8).position(x: c4, y: r2)
            }
        }
    }

    // MARK: - Tesla Control Row (semantic)

    private var controlRow: some View {
        HStack(spacing: 42) {
            controlIcon("music.note.list")
            controlIcon("fan.fill")
            controlIcon("light.min")
            controlIcon("video.fill")
        }
        .padding(.vertical, 14)
        .foregroundColor(.white.opacity(0.50))
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .medium))
            .padding(.horizontal, 10)
    }

    // MARK: - Tables & Bar

    private enum TableState {
        case inactive, active, warning

        var tint: Color {
            switch self {
            case .inactive: return Color.white.opacity(0.08)
            case .active:   return Color.orange.opacity(0.26)
            case .warning:  return Color.yellow.opacity(0.24)
            }
        }
    }

    private func table(_ state: TableState, seed: Int) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(woodBase)
            .overlay(
                RealWoodGrain(seed: seed)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(state.tint)
            )
            .frame(width: 66, height: 66)
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(woodBase) // ✅ same base as tables
            .overlay(
                RealWoodGrain(seed: 99, horizontal: true)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(TableState.active.tint) // ✅ same active tint as active table
            )
    }
    // MARK: - Materials

    private var woodBase: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.58, green: 0.44, blue: 0.30),
                Color(red: 0.42, green: 0.32, blue: 0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var darkWoodBase: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.30, green: 0.23, blue: 0.18),
                Color(red: 0.18, green: 0.14, blue: 0.11)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Wood Grain

private struct RealWoodGrain: View {
    let seed: Int
    var horizontal: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                srand48(seed)

                let lines = 12
                for i in 0..<lines {
                    let t = CGFloat(i) / CGFloat(lines)
                    let offset = CGFloat(drand48() * 10 - 5)
                    let thickness = CGFloat(drand48() * 1.5 + 1)
                    let alpha = Double(drand48() * 0.04 + 0.03)

                    let pos = horizontal ? t * size.height : t * size.width
                    let rect = horizontal
                        ? CGRect(x: 0, y: pos + offset, width: size.width, height: thickness)
                        : CGRect(x: pos + offset, y: 0, width: thickness, height: size.height)

                    ctx.fill(Path(rect), with: .color(Color.white.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
        .opacity(0.55)
    }
}

// MARK: - Preview

#Preview {
    AppleHomeStyleRestaurantMap()
}
