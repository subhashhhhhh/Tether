//
//  LiquidClockView.swift
//  Tether
//
//  AirSync-inspired lockscreen clock widget with SF Rounded typography,
//  stacked/horizontal adaptive layouts, and liquid glass styling.
//

import SwiftUI
import Combine

public struct LiquidClockView: View {
    public var isCompact: Bool

    @State private var currentDate = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(isCompact: Bool = false) {
        self.isCompact = isCompact
    }

    public var body: some View {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: currentDate)
        let minute = calendar.component(.minute, from: currentDate)

        let is24Hour = isSystemUsing24Hour()
        let displayHour = is24Hour ? hour : (hour % 12 == 0 ? 12 : hour % 12)
        let hourString = String(format: "%02d", displayHour)
        let minuteString = String(format: "%02d", minute)

        Group {
            if isCompact {
                // Horizontal compact clock
                HStack(spacing: 3) {
                    Text(hourString)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text(":")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .opacity(0.65)
                        .offset(y: -2)
                    Text(minuteString)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                }
            } else {
                // Stacked large lockscreen clock
                VStack(spacing: -16) {
                    Text(hourString)
                        .font(.system(size: 78, weight: .bold, design: .rounded))
                    Text(minuteString)
                        .font(.system(size: 78, weight: .bold, design: .rounded))
                }
            }
        }
        .foregroundStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.96),
                    Color.white.opacity(0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)
        .onReceive(timer) { newDate in
            currentDate = newDate
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isCompact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current time: \(hourString):\(minuteString)")
    }

    private func isSystemUsing24Hour() -> Bool {
        let formatString = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return !formatString.contains("a")
    }
}
