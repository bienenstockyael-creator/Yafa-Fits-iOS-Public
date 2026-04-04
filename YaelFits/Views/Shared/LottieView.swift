import SwiftUI
import Lottie

struct LottieWeatherIcon: View {
    let condition: String
    var size: CGFloat = 24

    var body: some View {
        if let name = lottieFileName {
            LottieView(animation: .named(name))
                .looping()
                .frame(width: size, height: size)
        } else {
            AppIcon(glyph: fallbackGlyph, size: size * 0.82, color: iconColor)
        }
    }

    private var visualKind: WeatherVisualKind {
        Weather(tempF: 0, tempC: 0, condition: condition).visualKind
    }

    private var lottieFileName: String? {
        switch visualKind {
        case .sunny, .clear:
            return "sunny"
        case .rainy:
            return "rainy"
        case .stormy:
            return "stormy"
        case .snowy:
            return "snowy"
        case .windy, .breezy:
            return "windy"
        case .cloudy, .partlyCloudy, .cold:
            return "cloudy"
        case .unknown:
            return nil
        }
    }

    private var fallbackGlyph: AppIconGlyph {
        switch visualKind {
        case .sunny, .clear:
            return .sun
        case .cloudy, .partlyCloudy, .rainy, .stormy, .cold, .unknown:
            return .cloud
        case .snowy:
            return .snowflake
        case .breezy, .windy:
            return .wind
        }
    }

    private var iconColor: Color {
        switch visualKind {
        case .sunny, .clear:
            return Color(red: 0.95, green: 0.75, blue: 0.2)
        case .rainy:
            return Color(red: 0.45, green: 0.65, blue: 0.9)
        case .stormy:
            return Color(red: 0.6, green: 0.5, blue: 0.85)
        case .snowy, .cold:
            return Color(red: 0.6, green: 0.78, blue: 0.95)
        case .cloudy, .partlyCloudy:
            return Color(red: 0.65, green: 0.68, blue: 0.72)
        case .breezy, .windy:
            return Color(red: 0.45, green: 0.8, blue: 0.72)
        case .unknown:
            return AppPalette.textSecondary.opacity(0.8)
        }
    }
}
