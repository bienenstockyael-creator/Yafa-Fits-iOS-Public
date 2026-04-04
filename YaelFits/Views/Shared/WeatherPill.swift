import SwiftUI

struct WeatherPill: View {
    let weather: Weather
    let useFahrenheit: Bool

    var body: some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            LottieWeatherIcon(condition: weather.condition, size: 22)

            Text(tempString)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.textSecondary)
        }
        .padding(.horizontal, LayoutMetrics.xSmall)
        .padding(.vertical, 7)
        .appCapsule(shadowRadius: 0, shadowY: 0)
        .shadow(color: weatherGlow, radius: 14, y: 0)
    }

    private var tempString: String {
        let temp = useFahrenheit ? weather.tempF : weather.tempC
        return "\(temp)\u{00B0}"
    }

    private var weatherGlow: Color {
        switch weather.visualKind {
        case .sunny, .clear:
            return Color(red: 1, green: 0.92, blue: 0.71).opacity(0.4)
        case .rainy:
            return Color(red: 0.71, green: 0.86, blue: 1).opacity(0.35)
        case .stormy:
            return Color(red: 0.82, green: 0.75, blue: 1).opacity(0.35)
        case .snowy, .cold:
            return Color(red: 0.88, green: 0.96, blue: 1).opacity(0.45)
        case .cloudy, .partlyCloudy:
            return Color(red: 0.9, green: 0.92, blue: 0.94).opacity(0.4)
        case .breezy, .windy:
            return Color(red: 0.75, green: 0.96, blue: 0.92).opacity(0.35)
        case .unknown:
            return Color.black.opacity(0.04)
        }
    }
}
