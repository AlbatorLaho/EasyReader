import SwiftUI

struct SliderControls<Label: View, ValueLabel: View, Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    private let label: () -> Label
    private let minimumValueLabel: () -> ValueLabel
    private let maximumValueLabel: () -> ValueLabel
    private let value: Binding<Value>
    private let bounds: ClosedRange<Value>
    private let step: Value.Stride
    private let formatter: NumberFormatter

    init(
        value: Binding<Value>, in bounds: ClosedRange<Value>, step: Value.Stride = 1, min: NSNumber? = 0, max: NSNumber? = nil,
        format: NumberFormatter.Style = .decimal, fractionDigits: ClosedRange<Int>? = nil, @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder minimumValueLabel: @escaping () -> ValueLabel,
        @ViewBuilder maximumValueLabel: @escaping () -> ValueLabel
    ) {
        self.label = label
        self.minimumValueLabel = minimumValueLabel
        self.maximumValueLabel = maximumValueLabel
        self.value = value
        self.bounds = bounds
        self.step = step
        formatter = NumberFormatter()
        formatter.numberStyle = format
        formatter.minimum = min
        formatter.maximum = max
        if let fractionDigits {
            formatter.minimumFractionDigits = fractionDigits.lowerBound
            formatter.maximumFractionDigits = fractionDigits.upperBound
        }
    }

    init<V: BinaryInteger>(
        value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, min: NSNumber? = 0, max: NSNumber? = nil, format: NumberFormatter.Style = .none,
        @ViewBuilder label: @escaping () -> Label, @ViewBuilder minimumValueLabel: @escaping () -> ValueLabel,
        @ViewBuilder maximumValueLabel: @escaping () -> ValueLabel
    ) where V.Stride: BinaryInteger, Value == Double {
        self.init(
            value: Binding(
                get: { Double(value.wrappedValue) },
                set: { newValue in value.wrappedValue = V(newValue) }
            ),
            in: Double(bounds.lowerBound)...Double(bounds.upperBound),
            step: Double(step),
            min: min,
            max: max,
            format: format,
            label: label,
            minimumValueLabel: minimumValueLabel,
            maximumValueLabel: maximumValueLabel
        )
    }

    var body: some View {
        HStack {
            Slider(value: value, in: bounds, step: step) {
                label()
            } minimumValueLabel: {
                minimumValueLabel()
            } maximumValueLabel: {
                maximumValueLabel()
            }
            TextField("", value: value, formatter: formatter)
                .frame(maxWidth: 48)
                .labelsHidden()
            Stepper("", value: value, in: bounds, step: step)
                .labelsHidden()
        }
    }
}
