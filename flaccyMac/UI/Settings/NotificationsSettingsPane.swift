import AppKit
import MidgarCore
import AuthenticationServices
import Combine
import FlaccyCore
import MidgarPortal
import ServiceManagement
import UserNotifications

/// Recap & Notifications: cadence, delivery time, and the permission banner.
final class NotificationsSettingsPane: SettingsPane {

    let frequencyPopUp = NSPopUpButton()
    let timePicker = NSDatePicker()
    let weekdayPopUp = NSPopUpButton()
    let monthDayPopUp = NSPopUpButton()
    let weekdayRow = NSStackView()
    let monthDayRow = NSStackView()
    let nextDeliveryLabel = NSTextField(labelWithString: "")
    let deniedBanner = NSStackView()
    let scheduler = MacRecapNotificationScheduler.shared

    override func buildForm() {
        buildDeniedBanner()
        formStack.addArrangedSubview(deniedBanner)
        deniedBanner.isHidden = true

        formStack.addArrangedSubview(sectionLabel(String(localized: "Recap Notifications")))
        for frequency in RecapNotificationFrequency.allCases {
            frequencyPopUp.addItem(withTitle: frequency.displayName)
        }
        frequencyPopUp.target = self
        frequencyPopUp.action = #selector(frequencyChanged)
        addRow([label(String(localized: "Frequency")), frequencyPopUp])

        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.target = self
        timePicker.action = #selector(timeChanged)
        addRow([label(String(localized: "Deliver at")), timePicker])

        let weekdays = Calendar.current.standaloneWeekdaySymbols
        for name in weekdays {
            weekdayPopUp.addItem(withTitle: name)
        }
        weekdayPopUp.target = self
        weekdayPopUp.action = #selector(weekdayChanged)
        weekdayRow.orientation = .horizontal
        weekdayRow.spacing = 8
        weekdayRow.addArrangedSubview(label(String(localized: "On")))
        weekdayRow.addArrangedSubview(weekdayPopUp)
        formStack.addArrangedSubview(weekdayRow)

        for day in 1...28 {
            monthDayPopUp.addItem(withTitle: String(localized: "Day \(day)"))
        }
        monthDayPopUp.target = self
        monthDayPopUp.action = #selector(monthDayChanged)
        monthDayRow.orientation = .horizontal
        monthDayRow.spacing = 8
        monthDayRow.addArrangedSubview(label(String(localized: "On")))
        monthDayRow.addArrangedSubview(monthDayPopUp)
        formStack.addArrangedSubview(monthDayRow)

        nextDeliveryLabel.font = .systemFont(ofSize: 11)
        nextDeliveryLabel.textColor = .secondaryLabelColor
        formStack.addArrangedSubview(nextDeliveryLabel)
        formStack.addArrangedSubview(separator())
        addFullWidth(explanation(String(localized: "A yearly Year in Music drop is always scheduled for December 1st while notifications are on.")))
    }

    func buildDeniedBanner() {
        deniedBanner.orientation = .horizontal
        deniedBanner.alignment = .centerY
        deniedBanner.spacing = 10
        deniedBanner.wantsLayer = true
        deniedBanner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        deniedBanner.layer?.cornerRadius = 10
        deniedBanner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "bell.slash.fill", accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .systemRed
        let text = NSTextField(wrappingLabelWithString: String(localized: "Notifications are turned off for Flaccy in System Settings."))
        text.font = .systemFont(ofSize: 12)
        let openButton = NSButton(title: String(localized: "Open System Settings"), target: self, action: #selector(openSystemSettings))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        deniedBanner.addArrangedSubview(icon)
        deniedBanner.addArrangedSubview(text)
        deniedBanner.addArrangedSubview(openButton)
    }

    func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        let frequency = scheduler.frequency
        frequencyPopUp.selectItem(at: RecapNotificationFrequency.allCases.firstIndex(of: frequency) ?? 0)
        var components = DateComponents()
        components.hour = scheduler.deliveryHour
        components.minute = scheduler.deliveryMinute
        timePicker.dateValue = Calendar.current.date(from: components) ?? Date()
        weekdayPopUp.selectItem(at: scheduler.weeklyWeekday - 1)
        monthDayPopUp.selectItem(at: scheduler.monthlyDay - 1)

        weekdayRow.isHidden = frequency != .weekly
        monthDayRow.isHidden = frequency != .monthly
        timePicker.isEnabled = frequency != .off
        renderNextDelivery()
        Task { [weak self] in
            let status = await MacRecapNotificationScheduler.shared.authorizationStatus()
            self?.deniedBanner.isHidden = status != .denied
        }
    }

    func renderNextDelivery() {
        if let next = scheduler.nextDeliveryDate() {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            nextDeliveryLabel.stringValue = String(localized: "Next recap: \(formatter.string(from: next))")
        } else {
            nextDeliveryLabel.stringValue = ""
        }
    }

    @objc func frequencyChanged() {
        let index = frequencyPopUp.indexOfSelectedItem
        guard index >= 0, index < RecapNotificationFrequency.allCases.count else { return }
        let frequency = RecapNotificationFrequency.allCases[index]
        Task { [weak self] in
            let granted = await MacRecapNotificationScheduler.shared.setFrequency(frequency)
            if !granted {
                self?.deniedBanner.isHidden = false
            }
            self?.refresh()
        }
    }

    @objc func timeChanged() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        scheduler.deliveryHour = components.hour ?? 19
        scheduler.deliveryMinute = components.minute ?? 0
        reschedule()
    }

    @objc func weekdayChanged() {
        scheduler.weeklyWeekday = weekdayPopUp.indexOfSelectedItem + 1
        reschedule()
    }

    @objc func monthDayChanged() {
        scheduler.monthlyDay = monthDayPopUp.indexOfSelectedItem + 1
        reschedule()
    }

    func reschedule() {
        Task { [weak self] in
            await MacRecapNotificationScheduler.shared.refreshSchedule(force: true)
            self?.renderNextDelivery()
        }
    }

    @objc func openSystemSettings() {
        MacSystemSettings.openNotifications()
    }
}
