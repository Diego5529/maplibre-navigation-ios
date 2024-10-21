import CoreLocation
import Solar
import UIKit

/**
 The `StyleManagerDelegate` protocol defines a set of methods used for controlling the style.
 */
@objc(MBStyleManagerDelegate)
public protocol StyleManagerDelegate: NSObjectProtocol {
    /**
     Asks the delegate for a location to use when calculating sunset and sunrise.
     */
    @objc func locationFor(styleManager: StyleManager) -> CLLocation?
    
    /**
     Informs the delegate that a style was applied.
     */
    @objc optional func styleManager(_ styleManager: StyleManager, didApply style: Style)
    
    /**
     Informs the delegate that the manager forcefully refreshed UIAppearance.
     */
    @objc optional func styleManagerDidRefreshAppearance(_ styleManager: StyleManager)
}

/**
 A manager that handles `Style` objects. The manager listens for significant time changes
 and changes to the content size to apply an approriate style for the given condition.
 */
@objc(MBStyleManager)
open class StyleManager: NSObject {
    /**
     The receiver of the delegate. See `StyleManagerDelegate` for more information.
     */
    @objc public weak var delegate: StyleManagerDelegate?
    
    /**
     Determines whether the style manager should apply a new style given the time of day.
     
     - precondition: Two styles must be provided for this property to have any effect.
     */
    @objc public var automaticallyAdjustsStyleForTimeOfDay = true {
        didSet {
            self.resetTimeOfDayTimer()
        }
    }
    
    /**
     The styles that are in circulation. Active style is set based on
     the sunrise and sunset at your current location. A change of
     preferred content size by the user will also trigger an update.
     
     - precondition: Two styles must be provided for
     `StyleManager.automaticallyAdjustsStyleForTimeOfDay` to have any effect.
     */
    @objc public var styles = [Style]() {
        didSet {
            self.applyStyle()
            self.resetTimeOfDayTimer()
        }
    }
    
    var date: Date?
    
    var currentStyleType: StyleType?
    
    /**
     Initializes a new `StyleManager`.
     
     - parameter delegate: The receiver’s delegate
     */
    public required init(_ delegate: StyleManagerDelegate) {
        self.delegate = delegate
        super.init()
        self.resumeNotifications()
        self.resetTimeOfDayTimer()
    }
    
    deinit {
        suspendNotifications()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(timeOfDayChanged), object: nil)
    }
    
    func resumeNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.timeOfDayChanged), name: UIApplication.significantTimeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.preferredContentSizeChanged(_:)), name: UIContentSizeCategory.didChangeNotification, object: nil)
    }
    
    func suspendNotifications() {
        NotificationCenter.default.removeObserver(self, name: UIContentSizeCategory.didChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.significantTimeChangeNotification, object: nil)
    }
    
    func resetTimeOfDayTimer() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.timeOfDayChanged), object: nil)
        
        guard self.automaticallyAdjustsStyleForTimeOfDay, self.styles.count > 1 else { return }
        guard let location = delegate?.locationFor(styleManager: self) else { return }
        
        guard let solar = Solar(date: date, coordinate: location.coordinate),
              let sunrise = solar.sunrise,
              let sunset = solar.sunset else {
            return
        }
        
        guard let interval = solar.date.intervalUntilTimeOfDayChanges(sunrise: sunrise, sunset: sunset) else {
            print("Unable to get sunrise or sunset. Automatic style switching has been disabled.")
            return
        }
        
        perform(#selector(self.timeOfDayChanged), with: nil, afterDelay: interval + 1)
    }
    
    @objc func preferredContentSizeChanged(_ notification: Notification) {
        self.applyStyle()
    }
    
    @objc func timeOfDayChanged() {
        self.forceRefreshAppearanceIfNeeded()
        self.resetTimeOfDayTimer()
    }
    
    func applyStyle(type styleType: StyleType) {
        guard self.currentStyleType != styleType else { return }
        
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.timeOfDayChanged), object: nil)
        
        for style in self.styles where style.styleType == styleType {
            style.apply()
            currentStyleType = styleType
            delegate?.styleManager?(self, didApply: style)
        }
        
        self.forceRefreshAppearance()
    }
    
    func applyStyle() {
        guard let location = delegate?.locationFor(styleManager: self) else {
            // We can't calculate sunset or sunrise w/o a location so just apply the first style
            if let style = styles.first, currentStyleType != style.styleType {
                self.currentStyleType = style.styleType
                style.apply()
                self.delegate?.styleManager?(self, didApply: style)
            }
            return
        }
        
        // Single style usage
        guard self.styles.count > 1 else {
            if let style = styles.first, currentStyleType != style.styleType {
                self.currentStyleType = style.styleType
                style.apply()
                self.delegate?.styleManager?(self, didApply: style)
            }
            return
        }
        
        let styleTypeForTimeOfDay = self.styleType(for: location)
        self.applyStyle(type: styleTypeForTimeOfDay)
    }
    
    func styleType(for location: CLLocation) -> StyleType {
        guard let solar = Solar(date: date, coordinate: location.coordinate),
              let sunrise = solar.sunrise,
              let sunset = solar.sunset else {
            return .day
        }
        
        return solar.date.isNighttime(sunrise: sunrise, sunset: sunset) ? .night : .day
    }
    
    func forceRefreshAppearanceIfNeeded() {
        guard let location = delegate?.locationFor(styleManager: self) else { return }
        
        let styleTypeForLocation = self.styleType(for: location)
        
        // If `styles` does not contain at least one style for the selected location, don't try and apply it.
        let availableStyleTypesForLocation = self.styles.filter { $0.styleType == styleTypeForLocation }
        guard availableStyleTypesForLocation.count > 0 else { return }
        
        guard self.currentStyleType != styleTypeForLocation else {
            return
        }
        
        self.applyStyle()
        self.forceRefreshAppearance()
    }
    
    func forceRefreshAppearance() {
        for window in UIApplication.shared.applicationWindows {
            for view in window.subviews {
                view.removeFromSuperview()
                window.addSubview(view)
            }
        }
        
        self.delegate?.styleManagerDidRefreshAppearance?(self)
    }
}

extension UIApplication {
    var applicationWindows: [UIWindow] {
        windows.filter { window in
            let className = String(describing: type(of: window))
            return !className.contains("UIRemoteKeyboardWindow") &&
            !className.contains("UIAlertController")
        }
    }
}

extension Date {
    func intervalUntilTimeOfDayChanges(sunrise: Date, sunset: Date) -> TimeInterval? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second], from: self)
        guard let date = calendar.date(from: components) else {
            return nil
        }
        
        if self.isNighttime(sunrise: sunrise, sunset: sunset) {
            let sunriseComponents = calendar.dateComponents([.hour, .minute, .second], from: sunrise)
            guard let sunriseDate = calendar.date(from: sunriseComponents) else {
                return nil
            }
            let interval = sunriseDate.timeIntervalSince(date)
            return interval >= 0 ? interval : (interval + 24 * 3600)
        } else {
            let sunsetComponents = calendar.dateComponents([.hour, .minute, .second], from: sunset)
            guard let sunsetDate = calendar.date(from: sunsetComponents) else {
                return nil
            }
            return sunsetDate.timeIntervalSince(date)
        }
    }
    
    fileprivate func isNighttime(sunrise: Date, sunset: Date) -> Bool {
        let calendar = Calendar.current
        let currentSecondsFromMidnight = calendar.component(.hour, from: self) * 3600 + calendar.component(.minute, from: self) * 60 + calendar.component(.second, from: self)
        let sunriseSecondsFromMidnight = calendar.component(.hour, from: sunrise) * 3600 + calendar.component(.minute, from: sunrise) * 60 + calendar.component(.second, from: sunrise)
        let sunsetSecondsFromMidnight = calendar.component(.hour, from: sunset) * 3600 + calendar.component(.minute, from: sunset) * 60 + calendar.component(.second, from: sunset)
        return currentSecondsFromMidnight < sunriseSecondsFromMidnight || currentSecondsFromMidnight > sunsetSecondsFromMidnight
    }
}

extension Solar {
    init?(date: Date?, coordinate: CLLocationCoordinate2D) {
        if let date {
            self.init(for: date, coordinate: coordinate)
        } else {
            self.init(coordinate: coordinate)
        }
    }
}
