//
//  ContentView.swift
//  Health History
//
//  Created by David Stolarsky on 5/6/26.
//

import Charts
import Combine
import HealthKit
import SwiftUI

private enum HealthRange: String, CaseIterable, Identifiable, Hashable {
    case day = "D"
    case week = "W"
    case month = "M"
    case sixMonths = "6M"
    case year = "Y"
    case decade = "10Y"
    case all = "ALL"

    var id: String { rawValue }

    var bucketComponent: Calendar.Component {
        switch self {
        case .day:
            return .hour
        case .week, .month:
            return .day
        case .sixMonths:
            return .weekOfYear
        case .year:
            return .month
        case .decade, .all:
            return .year
        }
    }

    func interval(containing anchorDate: Date, calendar: Calendar, availableInterval: DateInterval? = nil) -> DateInterval {
        switch self {
        case .day:
            return calendar.dateInterval(of: .day, for: anchorDate) ?? DateInterval(start: anchorDate, duration: 86_400)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchorDate) ?? DateInterval(start: anchorDate, duration: 604_800)
        case .month:
            return calendar.dateInterval(of: .month, for: anchorDate) ?? DateInterval(start: anchorDate, duration: 2_592_000)
        case .sixMonths:
            let end = calendar.dateInterval(of: .month, for: anchorDate)?.end ?? anchorDate
            let start = calendar.date(byAdding: .month, value: -6, to: end) ?? anchorDate
            return DateInterval(start: start, end: end)
        case .year:
            let end = calendar.dateInterval(of: .month, for: anchorDate)?.end ?? anchorDate
            let start = calendar.date(byAdding: .year, value: -1, to: end) ?? anchorDate
            return DateInterval(start: start, end: end)
        case .decade:
            let end = calendar.dateInterval(of: .year, for: anchorDate)?.end ?? anchorDate
            let start = calendar.date(byAdding: .year, value: -10, to: end) ?? anchorDate
            return DateInterval(start: start, end: end)
        case .all:
            return availableInterval ?? HealthRange.year.interval(containing: anchorDate, calendar: calendar)
        }
    }

    func bucketComponent(for interval: DateInterval) -> Calendar.Component {
        guard self == .all else {
            return bucketComponent
        }

        let days = interval.duration / 86_400
        switch days {
        case ...2:
            return .hour
        case ...45:
            return .day
        case ...365:
            return .weekOfYear
        case ...900:
            return .month
        default:
            return .year
        }
    }
}

private struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let endDate: Date
    let value: Double
    let rawValue: Double
}

private struct MetricSeries {
    var points: [ChartPoint] = []
    var summary: Double = 0
}

private struct CachedRangeData {
    let dataInterval: DateInterval
    let weight: MetricSeries
    let steps: MetricSeries
}

private extension DateInterval {
    var midpoint: Date {
        start.addingTimeInterval(duration / 2)
    }

    func clamped(to bounds: DateInterval?) -> DateInterval {
        guard let bounds else {
            return self
        }

        guard duration <= bounds.duration else {
            return bounds
        }

        if start < bounds.start {
            return DateInterval(start: bounds.start, end: bounds.start.addingTimeInterval(duration))
        }

        if end > bounds.end {
            return DateInterval(start: bounds.end.addingTimeInterval(-duration), end: bounds.end)
        }

        return self
    }
}

@MainActor
private final class HealthChartStore: ObservableObject {
    enum AccessState {
        case unknown
        case unavailable
        case authorized
        case denied(String)

        var requiresPrompt: Bool {
            switch self {
            case .authorized:
                return false
            case .unknown, .unavailable, .denied:
                return true
            }
        }
    }

    @Published var accessState: AccessState = .unknown
    @Published var weight = MetricSeries()
    @Published var steps = MetricSeries()
    @Published var isLoading = false
    @Published var availableInterval: DateInterval?

    private let store = HKHealthStore()
    private let calendar = Calendar.current
    private let sideBufferScale: TimeInterval = 1.5
    private var rangeCache: [HealthRange: CachedRangeData] = [:]
    private var preloadTask: Task<Void, Never>?
    private var loadSequence = 0

    private var weightType: HKQuantityType {
        HKQuantityType(.bodyMass)
    }

    private var stepType: HKQuantityType {
        HKQuantityType(.stepCount)
    }

    func requestAccess(range: HealthRange, anchorDate: Date) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            accessState = .unavailable
            return
        }

        do {
            try await store.requestAuthorization(toShare: [], read: [weightType, stepType])
            accessState = .authorized
            preloadTask?.cancel()
            rangeCache.removeAll()
            availableInterval = await loadAvailableInterval()
            await load(range: range, anchorDate: anchorDate)
        } catch {
            accessState = .denied(error.localizedDescription)
        }
    }

    func load(range: HealthRange, anchorDate: Date) async {
        await load(
            range: range,
            visibleInterval: visibleInterval(for: range, anchorDate: anchorDate),
            preloadAnchorDate: anchorDate
        )
    }

    func load(range: HealthRange, visibleInterval: DateInterval) async {
        guard case .authorized = accessState else {
            return
        }

        loadSequence += 1
        let sequence = loadSequence

        if let cachedData = cachedData(for: range, visibleInterval: visibleInterval) {
            apply(cachedData, visibleInterval: visibleInterval)
            isLoading = false
            return
        }

        isLoading = true
        let data = await fetchData(range: range, visibleInterval: visibleInterval)
        rangeCache[range] = data

        guard sequence == loadSequence else {
            return
        }

        apply(data, visibleInterval: visibleInterval)
        isLoading = false
        preloadRanges(anchorDate: visibleInterval.midpoint, skipping: range)
    }

    private func load(range: HealthRange, visibleInterval: DateInterval, preloadAnchorDate: Date) async {
        guard case .authorized = accessState else {
            return
        }

        loadSequence += 1
        let sequence = loadSequence

        if let cachedData = cachedData(for: range, visibleInterval: visibleInterval) {
            apply(cachedData, visibleInterval: visibleInterval)
            isLoading = false
            return
        }

        isLoading = true
        let data = await fetchData(range: range, visibleInterval: visibleInterval)
        rangeCache[range] = data

        guard sequence == loadSequence else {
            return
        }

        apply(data, visibleInterval: visibleInterval)
        isLoading = false
        preloadRanges(anchorDate: preloadAnchorDate, skipping: range)
    }

    func ensureBuffered(range: HealthRange, visibleInterval: DateInterval) async {
        guard case .authorized = accessState, range != .all else {
            return
        }

        let sequence = loadSequence

        if let cachedData = cachedData(for: range, visibleInterval: visibleInterval) {
            apply(cachedData, visibleInterval: visibleInterval)
            return
        }

        let data = await fetchData(range: range, visibleInterval: visibleInterval)
        guard !Task.isCancelled, sequence == loadSequence else {
            return
        }

        rangeCache[range] = data
        apply(data, visibleInterval: visibleInterval)
    }

    private func preloadRanges(anchorDate: Date, skipping currentRange: HealthRange? = nil) {
        guard case .authorized = accessState else {
            return
        }

        preloadTask?.cancel()
        preloadTask = Task(priority: .background) { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(for: .milliseconds(600))

            for range in HealthRange.allCases where range != currentRange {
                if Task.isCancelled {
                    return
                }

                await Task.yield()

                let visibleInterval = self.visibleInterval(for: range, anchorDate: anchorDate)

                if self.cachedData(for: range, visibleInterval: visibleInterval) != nil {
                    continue
                }

                let data = await self.fetchData(range: range, visibleInterval: visibleInterval)
                if Task.isCancelled {
                    return
                }
                self.rangeCache[range] = data
            }
        }
    }

    private func cachedData(for range: HealthRange, visibleInterval: DateInterval) -> CachedRangeData? {
        guard let data = rangeCache[range] else {
            return nil
        }

        let requiredInterval = bufferedInterval(for: visibleInterval, range: range)

        guard data.dataInterval.start <= requiredInterval.start, data.dataInterval.end >= requiredInterval.end else {
            return nil
        }

        return data
    }

    private func fetchData(range: HealthRange, visibleInterval: DateInterval) async -> CachedRangeData {
        let dataInterval = bufferedInterval(for: visibleInterval, range: range)
        async let loadedWeight = statistics(
            quantityType: weightType,
            unit: .pound(),
            options: .discreteAverage,
            range: range,
            dataInterval: dataInterval,
            visibleInterval: visibleInterval
        )
        async let loadedSteps = statistics(
            quantityType: stepType,
            unit: .count(),
            options: .cumulativeSum,
            range: range,
            dataInterval: dataInterval,
            visibleInterval: visibleInterval,
            normalizeToDailyAverage: true
        )

        let (weightPoints, stepPoints) = await (loadedWeight, loadedSteps)
        return CachedRangeData(
            dataInterval: dataInterval,
            weight: MetricSeries(points: weightPoints),
            steps: MetricSeries(points: stepPoints)
        )
    }

    private func apply(_ data: CachedRangeData, visibleInterval: DateInterval) {
        let visibleWeightPoints = points(data.weight.points, overlapping: visibleInterval)
        let visibleStepPoints = points(data.steps.points, overlapping: visibleInterval)
        weight = MetricSeries(points: data.weight.points, summary: average(visibleWeightPoints))
        steps = MetricSeries(points: data.steps.points, summary: dailyAverage(visibleStepPoints, in: visibleInterval))
    }

    private func bufferedInterval(for visibleInterval: DateInterval, range: HealthRange) -> DateInterval {
        guard range != .all else {
            return visibleInterval
        }

        let padding = visibleInterval.duration * sideBufferScale
        return DateInterval(
            start: visibleInterval.start.addingTimeInterval(-padding),
            end: visibleInterval.end.addingTimeInterval(padding)
        ).clamped(to: availableInterval)
    }

    private func visibleInterval(for range: HealthRange, anchorDate: Date) -> DateInterval {
        range.interval(
            containing: anchorDate,
            calendar: calendar,
            availableInterval: availableInterval
        )
        .clamped(to: range == .all ? nil : availableInterval)
    }

    private func points(_ points: [ChartPoint], overlapping interval: DateInterval) -> [ChartPoint] {
        points.filter { point in
            point.endDate > interval.start && point.date < interval.end
        }
    }

    private func statistics(
        quantityType: HKQuantityType,
        unit: HKUnit,
        options: HKStatisticsOptions,
        range: HealthRange,
        dataInterval: DateInterval,
        visibleInterval: DateInterval,
        normalizeToDailyAverage: Bool = false
    ) async -> [ChartPoint] {
        await withCheckedContinuation { continuation in
            var components = DateComponents()
            components.calendar = calendar
            components.setValue(1, for: range.bucketComponent(for: visibleInterval))

            let predicate = HKQuery.predicateForSamples(
                withStart: dataInterval.start,
                end: dataInterval.end,
                options: [.strictStartDate]
            )

            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: dataInterval.start,
                intervalComponents: components
            )

            query.initialResultsHandler = { _, collection, _ in
                guard let collection else {
                    continuation.resume(returning: [])
                    return
                }

                var points: [ChartPoint] = []
                collection.enumerateStatistics(from: dataInterval.start, to: dataInterval.end) { statistics, _ in
                    let quantity = options.contains(.cumulativeSum) ? statistics.sumQuantity() : statistics.averageQuantity()
                    guard let value = quantity?.doubleValue(for: unit) else {
                        return
                    }
                    let endDate = min(statistics.endDate, dataInterval.end)
                    let chartValue: Double
                    if normalizeToDailyAverage {
                        let days = max(1, self.calendar.dateComponents([.day], from: statistics.startDate, to: endDate).day ?? 1)
                        chartValue = value / Double(days)
                    } else {
                        chartValue = value
                    }
                    points.append(
                        ChartPoint(
                            date: statistics.startDate,
                            endDate: endDate,
                            value: chartValue,
                            rawValue: value
                        )
                    )
                }
                continuation.resume(returning: points)
            }

            store.execute(query)
        }
    }

    private func average(_ points: [ChartPoint]) -> Double {
        guard !points.isEmpty else {
            return 0
        }
        return points.map(\.value).reduce(0, +) / Double(points.count)
    }

    private func dailyAverage(_ points: [ChartPoint], in interval: DateInterval) -> Double {
        let days = max(1, calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
        return points.map(\.rawValue).reduce(0, +) / Double(days)
    }

    private func loadAvailableInterval() async -> DateInterval? {
        async let weightBounds = sampleBounds(for: weightType)
        async let stepBounds = sampleBounds(for: stepType)
        let bounds = await [weightBounds, stepBounds].compactMap { $0 }

        guard
            let start = bounds.map(\.start).min(),
            let end = bounds.map(\.end).max(),
            start < end
        else {
            return nil
        }

        return DateInterval(start: start, end: end)
    }

    private func sampleBounds(for sampleType: HKSampleType) async -> DateInterval? {
        async let first = boundarySample(for: sampleType, ascending: true)
        async let last = boundarySample(for: sampleType, ascending: false)

        guard let firstSample = await first, let lastSample = await last else {
            return nil
        }

        return DateInterval(start: firstSample.startDate, end: lastSample.endDate)
    }

    private func boundarySample(for sampleType: HKSampleType, ascending: Bool) async -> HKSample? {
        await withCheckedContinuation { continuation in
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                continuation.resume(returning: samples?.first)
            }
            store.execute(query)
        }
    }
}

struct ContentView: View {
    @StateObject private var healthStore = HealthChartStore()
    @AppStorage("hasRequestedHealthAccess") private var hasRequestedHealthAccess = false
    @State private var selectedRange: HealthRange = .year
    @State private var anchorDate = Date()
    @State private var settledVisibleInterval: DateInterval?
    @State private var dragStartInterval: DateInterval?
    @State private var dragTranslation: CGFloat = 0
    @State private var bufferTask: Task<Void, Never>?

    private let calendar = Calendar.current
    private let chartDragWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let isShowingAccessView = healthStore.accessState.requiresPrompt
            let accessHeight: CGFloat = isShowingAccessView ? 104 : 0
            let chromeHeight: CGFloat = 58 + accessHeight + (isShowingAccessView ? 10 : 0) + 24
            let chartHeight = max(150, (proxy.size.height - chromeHeight - 2 * 86 - 12) / 2)

            VStack(spacing: 10) {
                rangePicker
                    .padding(.horizontal, 18)

                accessView
                    .padding(.horizontal, 18)

                HealthMetricChart(
                    title: "AVERAGE",
                    value: healthStore.weight.summary,
                    unit: "lbs",
                    interval: visibleInterval,
                    range: selectedRange,
                    points: healthStore.weight.points,
                    style: .line(color: .purple),
                    isLoading: healthStore.isLoading,
                    chartHeight: chartHeight,
                    showsXAxisLabels: false
                )
                .simultaneousGesture(chartDragGesture)

                HealthMetricChart(
                    title: "DAILY AVERAGE",
                    value: healthStore.steps.summary,
                    unit: "steps",
                    interval: visibleInterval,
                    range: selectedRange,
                    points: healthStore.steps.points,
                    style: .bar(color: .orange),
                    isLoading: healthStore.isLoading,
                    chartHeight: chartHeight,
                    showsXAxisLabels: true
                )
                .simultaneousGesture(chartDragGesture)

                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            .padding(.bottom, 12)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .task {
            if hasRequestedHealthAccess {
                await healthStore.requestAccess(range: selectedRange, anchorDate: anchorDate)
            }
        }
        .onChange(of: selectedRange) { _, newRange in
            resetDrag()
            Task {
                await healthStore.load(range: newRange, anchorDate: anchorDate)
            }
        }
    }

    private var baseInterval: DateInterval {
        if let dragStartInterval {
            return dragStartInterval
        }

        if let settledVisibleInterval, selectedRange != .all {
            return settledVisibleInterval
        }

        return selectedRange.interval(
            containing: anchorDate,
            calendar: calendar,
            availableInterval: healthStore.availableInterval
        )
        .clamped(to: selectedRange == .all ? nil : healthStore.availableInterval)
    }

    private var visibleInterval: DateInterval {
        guard selectedRange != .all else {
            return selectedRange.interval(
                containing: anchorDate,
                calendar: calendar,
                availableInterval: healthStore.availableInterval
            )
            .clamped(to: selectedRange == .all ? nil : healthStore.availableInterval)
        }

        if dragTranslation == 0 {
            return settledVisibleInterval ?? baseInterval
        }

        return dragInterval(for: dragTranslation)
    }

    private var chartDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard selectedRange != .all, abs(value.translation.width) > abs(value.translation.height) * 1.35 else {
                    return
                }
                if dragStartInterval == nil {
                    dragStartInterval = visibleInterval
                }
                dragTranslation = value.translation.width
                ensureBufferedData(for: dragInterval(for: value.translation.width))
            }
            .onEnded { value in
                guard selectedRange != .all, dragStartInterval != nil else {
                    resetDrag()
                    return
                }

                let releasedInterval = dragInterval(for: value.translation.width)
                settledVisibleInterval = releasedInterval
                anchorDate = releasedInterval.midpoint
                resetDrag()
                Task {
                    await healthStore.load(range: selectedRange, visibleInterval: releasedInterval)
                }
            }
    }

    private var rangePicker: some View {
        Picker("Range", selection: rangeSelection) {
            ForEach(HealthRange.allCases) { range in
                Text(range.rawValue)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20))
    }

    private var rangeSelection: Binding<HealthRange> {
        Binding {
            selectedRange
        } set: { newRange in
            anchorDate = visibleInterval.midpoint
            settledVisibleInterval = nil
            selectedRange = newRange
        }
    }

    @ViewBuilder
    private var accessView: some View {
        switch healthStore.accessState {
        case .unknown:
            permissionCard(message: "Health History uses read-only access to your weight and step count to draw these charts.")
        case .unavailable:
            permissionCard(message: "Health data is not available on this device.")
        case .authorized:
            EmptyView()
        case .denied(let message):
            permissionCard(message: "Health access is needed to show your weight and steps. \(message)")
        }
    }

    private func permissionCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                hasRequestedHealthAccess = true
                Task {
                    await healthStore.requestAccess(range: selectedRange, anchorDate: anchorDate)
                }
            } label: {
                Label("Allow Health Access", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func dragOffsetSeconds(for translation: CGFloat, in interval: DateInterval) -> TimeInterval {
        -TimeInterval(translation / chartDragWidth) * interval.duration
    }

    private func dragInterval(for translation: CGFloat) -> DateInterval {
        let offset = dragOffsetSeconds(for: translation, in: baseInterval)
        return DateInterval(
            start: baseInterval.start.addingTimeInterval(offset),
            end: baseInterval.end.addingTimeInterval(offset)
        )
        .clamped(to: selectedRange == .all ? nil : healthStore.availableInterval)
    }

    private func ensureBufferedData(for interval: DateInterval) {
        bufferTask?.cancel()
        let range = selectedRange
        bufferTask = Task {
            await healthStore.ensureBuffered(range: range, visibleInterval: interval)
        }
    }

    private func resetDrag() {
        bufferTask?.cancel()
        dragStartInterval = nil
        dragTranslation = 0
    }
}

private struct HealthMetricChart: View {
    enum Style {
        case line(color: Color)
        case bar(color: Color)

        var color: Color {
            switch self {
            case .line(let color), .bar(let color):
                return color
            }
        }
    }

    let title: String
    let value: Double
    let unit: String
    let interval: DateInterval
    let range: HealthRange
    let points: [ChartPoint]
    let style: Style
    let isLoading: Bool
    let chartHeight: CGFloat
    let showsXAxisLabels: Bool

    private var formattedValue: String {
        if unit == "steps" {
            value.formatted(.number.precision(.fractionLength(0)))
        } else {
            value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    private var rawYDomain: ClosedRange<Double> {
        guard !visiblePoints.isEmpty else {
            return 0...1
        }

        let values = visiblePoints.map(\.value)
        guard let minimum = values.min(), let maximum = values.max() else {
            return 0...1
        }

        switch style {
        case .line:
            let spread = maximum - minimum
            let padding = max(spread * 0.2, 1)
            return (minimum - padding)...(maximum + padding)
        case .bar:
            return 0...max(maximum * 1.12, 1)
        }
    }

    private var yDomain: ClosedRange<Double> {
        niceYDomain(for: rawYDomain)
    }

    private var yAxisValues: [Double] {
        niceTicks(for: yDomain, targetCount: 4)
    }

    private var yAxisLabelValues: [Double] {
        let labels: [Double]
        switch style {
        case .line:
            labels = yAxisValues
        case .bar:
            labels = yAxisValues.filter { $0 > yDomainStepEpsilon }
        }

        return thinnedYAxisLabels(labels)
    }

    private var yDomainStepEpsilon: Double {
        max(abs(yDomain.upperBound - yDomain.lowerBound) * 0.000_001, 0.000_001)
    }

    private var visiblePoints: [ChartPoint] {
        points.filter { point in
            point.endDate > interval.start && point.date < interval.end
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(formattedValue)
                    .font(.system(size: 42, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            Chart {
                ForEach(points) { point in
                    switch style {
                    case .line:
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value(unit, point.value)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(style.color)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value(unit, point.value)
                        )
                        .symbolSize(70)
                        .foregroundStyle(style.color)
                    case .bar:
                        RectangleMark(
                            xStart: .value("Start", barStartDate(for: point)),
                            xEnd: .value("End", barEndDate(for: point)),
                            yStart: .value("Baseline", 0),
                            yEnd: .value(unit, point.value)
                        )
                        .foregroundStyle(style.color)
                    }
                }
            }
            .chartXScale(domain: interval.start...interval.end)
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .trailing, values: yAxisValues) { _ in
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: xGridStride.component, count: xGridStride.count)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        .foregroundStyle(Color(.systemGray4))
                }
                if showsXAxisLabels {
                    AxisMarks(values: xMajorLabelTicks.map(\.date)) { value in
                        if let date = value.as(Date.self), let tick = xMajorLabelTicks.first(where: { $0.date == date }) {
                            AxisValueLabel {
                                Text(tick.label)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color(.systemGray2))
                            }
                        }
                    }
                    AxisMarks(values: xMinorLabelTicks.map(\.date)) { value in
                        if let date = value.as(Date.self), let tick = xMinorLabelTicks.first(where: { $0.date == date }) {
                            AxisValueLabel {
                                Text(tick.label)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color(.systemGray3))
                            }
                        }
                    }
                }
            }
            .frame(height: chartHeight)
            .chartBackground { chartProxy in
                GeometryReader { geometry in
                    if let plotFrame = chartProxy.plotFrame {
                        let plotRect = geometry[plotFrame]
                        ForEach(yAxisValues, id: \.self) { yValue in
                            if let yPosition = chartProxy.position(forY: yValue) {
                                Path { path in
                                    let y = plotRect.origin.y + yPosition
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                                }
                                .stroke(Color(.systemGray5), lineWidth: 1)
                            }
                        }
                    }
                }
            }
            .chartOverlay { chartProxy in
                GeometryReader { geometry in
                    if let plotFrame = chartProxy.plotFrame {
                        let plotRect = geometry[plotFrame]
                        ForEach(yAxisLabelValues, id: \.self) { yValue in
                            if let yPosition = chartProxy.position(forY: yValue) {
                                yAxisLabel(yValue)
                                    .position(
                                        x: geometry.size.width - 36,
                                        y: plotRect.origin.y + yPosition
                                    )
                                    .zIndex(10)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                if visiblePoints.isEmpty {
                    ContentUnavailableView(
                        isLoading ? "Loading" : "No Data",
                        systemImage: isLoading ? "arrow.triangle.2.circlepath" : "chart.xyaxis.line",
                        description: Text(isLoading ? "Reading Health data." : "No \(unit) data is available for this range.")
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func yAxisText(_ value: Double) -> String {
        if unit == "steps" {
            return value.formatted(.number.precision(.fractionLength(0)))
        }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_001 {
            return rounded.formatted(.number.precision(.fractionLength(0)))
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private func yAxisLabel(_ value: Double) -> some View {
        Text(yAxisText(value))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassEffect(in: Capsule())
    }

    private struct XAxisTick: Identifiable {
        let date: Date
        let label: String

        var id: Date { date }
    }

    private var xGridStride: (component: Calendar.Component, count: Int) {
        switch range {
        case .day:
            return (.hour, 3)
        case .week, .month:
            return (.day, 1)
        case .sixMonths:
            return (.weekOfYear, 1)
        case .year:
            return (.month, 1)
        case .decade:
            return (.year, 1)
        case .all:
            switch range.bucketComponent(for: interval) {
            case .hour:
                return (.hour, 6)
            case .day:
                return (.day, 7)
            case .weekOfYear:
                return (.weekOfYear, 2)
            case .month:
                return (.month, 1)
            default:
                return (.year, 1)
            }
        }
    }

    private var xMajorLabelTicks: [XAxisTick] {
        let component = xMajorLabelComponent
        let boundaries = dates(matching: component, step: 1, in: interval)
        let boundaryTicks = boundaries.map { date in
            XAxisTick(date: date, label: xMajorLabel(for: date, component: component))
        }

        if boundaryTicks.isEmpty, let label = xLeftEdgeMajorLabel {
            return [XAxisTick(date: interval.start, label: label)]
        }

        return boundaryTicks
    }

    private var xMinorLabelTicks: [XAxisTick] {
        let rawTicks = dates(matching: xMinorLabelStride.component, step: xMinorLabelStride.count, in: interval)
            .filter { date in
                !isDate(date, nearAny: xMajorLabelTicks.map(\.date), tolerance: xMajorMinorCollisionTolerance)
            }
            .map { date in
                XAxisTick(date: date, label: xMinorLabel(for: date))
            }

        return thinXAxisTicks(rawTicks, preserving: xMajorLabelTicks)
    }

    private var xMajorLabelComponent: Calendar.Component {
        switch range {
        case .day:
            return .day
        case .week, .month, .sixMonths:
            return .month
        case .year, .decade:
            return .year
        case .all:
            switch range.bucketComponent(for: interval) {
            case .hour, .day, .weekOfYear:
                return .month
            default:
                return .year
            }
        }
    }

    private var xLeftEdgeMajorLabel: String? {
        switch xMajorLabelComponent {
        case .day:
            return shortMonthDayFormatter.string(from: interval.start)
        case .month:
            return monthFormatter.string(from: interval.start)
        case .year:
            return yearFormatter.string(from: interval.start)
        default:
            return nil
        }
    }

    private var xMajorMinorCollisionTolerance: TimeInterval {
        switch xMajorLabelComponent {
        case .day:
            return 3_600
        case .month:
            return 86_400
        case .year:
            return 86_400 * 7
        default:
            return 1
        }
    }

    private var xMinorLabelStride: (component: Calendar.Component, count: Int) {
        switch range {
        case .day:
            return (.hour, 6)
        case .week:
            return (.day, 1)
        case .month:
            return (.day, 7)
        case .sixMonths:
            return (.month, 1)
        case .year:
            return (.month, 3)
        case .decade:
            return (.year, 1)
        case .all:
            switch range.bucketComponent(for: interval) {
            case .hour:
                return (.hour, 12)
            case .day:
                return (.day, 14)
            case .weekOfYear:
                return (.month, 1)
            case .month:
                return (.month, 3)
            default:
                return (.year, 2)
            }
        }
    }

    private var maximumMinorXAxisLabels: Int {
        switch range {
        case .day, .week:
            return 4
        case .month, .sixMonths, .year:
            return 3
        case .decade, .all:
            return 4
        }
    }

    private var monthFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM"
        return formatter
    }

    private var shortMonthDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d"
        return formatter
    }

    private var hourFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("ha")
        return formatter
    }

    private var yearFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy"
        return formatter
    }

    private func xMajorLabel(for date: Date, component: Calendar.Component) -> String {
        switch component {
        case .day:
            return shortMonthDayFormatter.string(from: date)
        case .month:
            return monthFormatter.string(from: date)
        case .year:
            return yearFormatter.string(from: date)
        default:
            return ""
        }
    }

    private func xMinorLabel(for date: Date) -> String {
        switch xMinorLabelStride.component {
        case .hour:
            return hourFormatter.string(from: date)
        case .day:
            return dayFormatter.string(from: date)
        case .month:
            return monthFormatter.string(from: date)
        case .year:
            return yearFormatter.string(from: date)
        default:
            return ""
        }
    }

    private func dates(matching component: Calendar.Component, step: Int, in interval: DateInterval) -> [Date] {
        guard step > 0, var date = Calendar.current.dateInterval(of: component, for: interval.start)?.start else {
            return []
        }

        let tolerance: TimeInterval = 0.001
        if date < interval.start.addingTimeInterval(-tolerance) {
            guard let nextDate = Calendar.current.date(byAdding: component, value: step, to: date) else {
                return []
            }
            date = nextDate
        }

        var dates: [Date] = []
        while date <= interval.end.addingTimeInterval(tolerance) {
            if date >= interval.start.addingTimeInterval(-tolerance) {
                dates.append(date)
            }

            guard let nextDate = Calendar.current.date(byAdding: component, value: step, to: date), nextDate > date else {
                break
            }
            date = nextDate
        }

        return dates
    }

    private func isDate(_ date: Date, nearAny dates: [Date], tolerance: TimeInterval) -> Bool {
        dates.contains { abs($0.timeIntervalSince(date)) <= tolerance }
    }

    private func thinXAxisTicks(_ ticks: [XAxisTick], preserving majorTicks: [XAxisTick]) -> [XAxisTick] {
        guard ticks.count > maximumMinorXAxisLabels else {
            return ticks
        }

        let stride = Int(ceil(Double(ticks.count) / Double(maximumMinorXAxisLabels)))
        return ticks.enumerated().compactMap { index, tick in
            index.isMultiple(of: stride) ? tick : nil
        }
    }

    private func barStartDate(for point: ChartPoint) -> Date {
        point.date.addingTimeInterval(barInset(for: point))
    }

    private func barEndDate(for point: ChartPoint) -> Date {
        point.endDate.addingTimeInterval(-barInset(for: point))
    }

    private func barInset(for point: ChartPoint) -> TimeInterval {
        max(0, point.endDate.timeIntervalSince(point.date) * 0.08)
    }

    private func niceYDomain(for domain: ClosedRange<Double>) -> ClosedRange<Double> {
        let lower = domain.lowerBound
        let upper = domain.upperBound
        guard lower.isFinite, upper.isFinite, lower < upper else {
            return 0...1
        }

        let step = niceTickStep(start: lower, stop: upper, count: 4)
        guard step > 0 else {
            return domain
        }

        switch style {
        case .line:
            let niceLower = floor(lower / step) * step
            let niceUpper = ceil(upper / step) * step
            return niceLower...niceUpper
        case .bar:
            let niceUpper = ceil(upper / step) * step
            return 0...max(niceUpper, step)
        }
    }

    private func niceTicks(for domain: ClosedRange<Double>, targetCount: Int) -> [Double] {
        let lower = domain.lowerBound
        let upper = domain.upperBound
        guard lower.isFinite, upper.isFinite, lower < upper else {
            return []
        }

        let step = niceTickStep(start: lower, stop: upper, count: targetCount)
        guard step > 0 else {
            return []
        }

        let first = ceil(lower / step) * step
        let last = floor(upper / step) * step
        let decimalPlaces = max(0, -Int(floor(log10(step))))
        var ticks: [Double] = []
        var value = first

        while value <= last + step * 0.5 {
            ticks.append(round(value, decimalPlaces: decimalPlaces))
            value += step
        }

        return ticks.reversed()
    }

    private func thinnedYAxisLabels(_ labels: [Double]) -> [Double] {
        guard labels.count > 4 else {
            return labels
        }

        return labels.enumerated().compactMap { index, label in
            index.isMultiple(of: 2) ? label : nil
        }
    }

    private func niceTickStep(start: Double, stop: Double, count: Int) -> Double {
        let rawStep = abs(stop - start) / Double(max(1, count))
        guard rawStep.isFinite, rawStep > 0 else {
            return 0
        }

        let power = floor(log10(rawStep))
        let base = pow(10, power)
        let error = rawStep / base

        let factor: Double
        if error >= sqrt(50) {
            factor = 10
        } else if error >= sqrt(10) {
            factor = 5
        } else if error >= sqrt(2) {
            factor = 2
        } else {
            factor = 1
        }

        return factor * base
    }

    private func round(_ value: Double, decimalPlaces: Int) -> Double {
        guard decimalPlaces > 0 else {
            return value.rounded()
        }

        let scale = pow(10, Double(decimalPlaces))
        return (value * scale).rounded() / scale
    }
}

#Preview {
    ContentView()
}
