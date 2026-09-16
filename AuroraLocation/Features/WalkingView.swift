import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct WalkingView: View {
    @EnvironmentObject private var state: AppState

    @State private var start: Coordinate?
    @State private var startName = ""
    @State private var end: Coordinate?
    @State private var endName = ""
    @State private var plannedRoute: WalkingRoute?
    @State private var routeError: String?
    @State private var isPlanning = false
    @State private var speedKmh = 4.5
    @State private var pickerTarget: WalkingLocationPickerTarget?
    @State private var planningTask: Task<Void, Never>?
    @State private var directions: MKDirections?
    @State private var activePlanningID: UUID?

    private var session: WalkingSession? { state.walkingSession }

    private var route: WalkingRoute? {
        if let session, !isInterrupted(session) { return session.route }
        return plannedRoute
    }

    private var isRouteLocked: Bool {
        guard let session else { return false }
        return !isInterrupted(session)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WalkingMapView(
                        route: route,
                        current: session?.coordinate,
                        start: start,
                        end: end
                    )
                    .frame(minHeight: 285)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("步行路线地图")
                }

                if isRouteLocked, let session {
                    sessionSection(session)
                } else {
                    planningSection
                }

                if route?.source == .openStreetMap {
                    Section("路线来源") {
                        Text("步行路线由 FOSSGIS / OSRM 提供, 起终点已吸附到附近道路.")
                            .font(.footnote)
                        Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        Link("修正地图数据", destination: URL(string: "https://www.openstreetmap.org/fixthemap")!)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("模拟步行")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") { state.showSetup = true }
                }
            }
            .overlay {
                if isPlanning || (state.isBusy && !state.isWalkingSessionActive) {
                    ProgressView(isPlanning ? "正在规划步行路线" : "正在开始模拟步行")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            if start == nil {
                start = state.selected
                startName = state.selectedName
            }
        }
        .sheet(item: $pickerTarget) { target in
            WalkingLocationPickerView(
                title: target.title,
                initialCoordinate: target == .start ? start ?? state.selected : end ?? start ?? state.selected,
                initialName: target == .start ? startName : endName
            ) { coordinate, name in
                applyEndpoint(target, coordinate: coordinate, name: name)
            }
        }
        .onDisappear {
            cancelRoutePlanning()
        }
    }

    @ViewBuilder
    private var planningSection: some View {
        Section {
            endpointButton(title: "起点", coordinate: start, name: startName, target: .start)
            endpointButton(title: "终点", coordinate: end, name: endName, target: .end)

            if let routeError {
                Label(routeError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("规划步行路线", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                planRoute()
            }
            .disabled(isPlanning || start == nil || end == nil || state.isBusy || state.pairing.isBusy)
        } header: {
            Text("路线")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("优先使用 Apple 路线. 服务失败时自动向 FOSSGIS 发送起终点规划步行路线; 该服务会记录请求.")
                Link("备选路线服务与隐私", destination: URL(string: "https://routing.openstreetmap.de/about.html")!)
            }
        }

        if let plannedRoute {
            Section("路线预览") {
                LabeledContent("距离", value: distanceText(plannedRoute.distance))
                Picker("速度", selection: $speedKmh) {
                    ForEach(Array(stride(from: 1.0, through: 8.0, by: 0.5)), id: \.self) { speed in
                        Text(speedText(speed)).tag(speed)
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(state.isBusy || state.pairing.isBusy)

                LabeledContent("预计用时", value: durationText(secondsFor: plannedRoute.distance, speedKmh: speedKmh))

                Button("开始模拟步行", systemImage: "play.fill") {
                    Task { await state.startWalking(route: plannedRoute, speedKmh: speedKmh) }
                }
                .disabled(state.isBusy || state.pairing.isBusy)
            }
        }

        if let session, isInterrupted(session) {
            Section("上次会话") {
                Label("步行已中断, 系统定位状态未知. 重新开始会从路线起点出发.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("恢复真实定位", systemImage: "location.slash.fill", role: .destructive) {
                    Task { await state.execute(.clear) }
                }
                .disabled(state.isBusy || state.pairing.isBusy)
            }
        }
    }

    @ViewBuilder
    private func sessionSection(_ session: WalkingSession) -> some View {
        Section("步行状态") {
            LabeledContent("距离", value: "\(distanceText(session.distanceTraveled)) / \(distanceText(session.route.distance))")
            ProgressView(value: session.progress) {
                Text("进度")
            } currentValueLabel: {
                Text(session.progress, format: .percent.precision(.fractionLength(0)))
            }
            LabeledContent("剩余时间", value: durationText(secondsFor: max(0, session.route.distance - session.distanceTraveled), speedKmh: session.speedKmh))

            switch session.phase {
            case .walking:
                Label("正在模拟步行", systemImage: "figure.walk")
                    .foregroundStyle(.green)
                Button("暂停", systemImage: "pause.fill") {
                    state.pauseWalking()
                }
                .disabled(state.isBusy || state.pairing.isBusy)
            case .paused:
                Label("已暂停, 当前位置会保持不变", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
                Button("继续", systemImage: "play.fill") {
                    state.resumeWalking()
                }
                .disabled(state.isBusy || state.pairing.isBusy)
            case .arrived:
                Label("已到达终点, 当前位置会保持在终点", systemImage: "flag.checkered")
                    .foregroundStyle(.green)
            case .interrupted:
                EmptyView()
            }

            Button("结束模拟步行", systemImage: "stop.fill", role: .destructive) {
                Task { await state.execute(.clear) }
            }
            .disabled(state.isBusy || state.pairing.isBusy)
            .accessibilityHint("此操作会发送恢复真实定位请求")
        }
    }

    private func endpointButton(title: String, coordinate: Coordinate?, name: String, target: WalkingLocationPickerTarget) -> some View {
        Button {
            pickerTarget = target
        } label: {
            LabeledContent(title) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(name.isEmpty ? (coordinate?.label ?? "请选择") : name)
                    if let coordinate {
                        Text(coordinate.label)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(isPlanning || state.isBusy || state.pairing.isBusy)
        .accessibilityHint("打开地图和搜索以选择\(title)")
    }

    private func applyEndpoint(_ target: WalkingLocationPickerTarget, coordinate: Coordinate, name: String?) {
        guard !isRouteLocked else { return }
        switch target {
        case .start:
            start = coordinate
            startName = name ?? coordinate.label
        case .end:
            end = coordinate
            endName = name ?? coordinate.label
        }
        invalidateRoute()
    }

    private func planRoute() {
        guard let start, let end else { return }
        cancelRoutePlanning()
        let planningID = UUID()
        activePlanningID = planningID
        isPlanning = true
        routeError = nil
        plannedRoute = nil

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude)))
        request.transportType = .walking
        let directions = MKDirections(request: request)
        self.directions = directions

        planningTask = Task { @MainActor in
            defer {
                if activePlanningID == planningID {
                    isPlanning = false
                    self.directions = nil
                }
            }
            do {
                let response = try await directions.calculate()
                guard !Task.isCancelled,
                      activePlanningID == planningID,
                      self.start == start,
                      self.end == end else { return }
                guard let mapRoute = response.routes.first else {
                    throw MKError(.directionsNotFound)
                }
                let coordinates = mapRoute.polyline.walkingCoordinates
                guard let route = WalkingRoute(coordinates: coordinates) else {
                    routeError = "未能生成可用的步行路线. 请调整起点或终点后重试."
                    return
                }
                plannedRoute = route
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, activePlanningID == planningID else { return }
                guard WalkingRoute.canUseAlternateService(after: error) else {
                    routeError = WalkingRoute.planningErrorMessage(error)
                    return
                }
                do {
                    let fallback = try await OpenStreetMapWalkingRoute.fetch(from: start, to: end)
                    guard !Task.isCancelled, activePlanningID == planningID,
                          self.start == start, self.end == end else { return }
                    plannedRoute = fallback
                } catch {
                    guard !Task.isCancelled, activePlanningID == planningID else { return }
                    routeError = "Apple 路线不可用. " + ((error as? OpenStreetMapWalkingRoute.Failure)?.errorDescription ?? "备选步行服务请求失败, 请稍后重试.")
                }
            }
        }
    }

    private func invalidateRoute() {
        cancelRoutePlanning()
        plannedRoute = nil
        routeError = nil
    }

    private func cancelRoutePlanning() {
        planningTask?.cancel()
        directions?.cancel()
        planningTask = nil
        directions = nil
        activePlanningID = nil
        isPlanning = false
    }

    private func distanceText(_ distance: Double) -> String {
        if distance >= 1_000 { return String(format: "%.2f km", distance / 1_000) }
        return String(format: "%.0f m", distance)
    }

    private func durationText(secondsFor distance: Double, speedKmh: Double) -> String {
        let seconds = max(0, distance / (speedKmh * 1_000 / 3_600))
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes > 0 else { return "已到达" }
        if minutes < 60 { return "约 \(minutes) 分钟" }
        return "约 \(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    private func speedText(_ speed: Double) -> String {
        String(format: "%.1f km/h", speed)
    }

    private func isInterrupted(_ session: WalkingSession) -> Bool {
        if case .interrupted = session.phase { return true }
        return false
    }
}

private enum WalkingLocationPickerTarget: String, Identifiable, Equatable {
    case start
    case end

    var id: Self { self }
    var title: String { self == .start ? "选择起点" : "选择终点" }
}

private struct WalkingLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialCoordinate: Coordinate
    let initialName: String
    let onSelect: (Coordinate, String?) -> Void

    @State private var selected: Coordinate
    @State private var selectedName: String
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var localSearch: MKLocalSearch?
    @State private var searchID: UUID?
    @State private var showingCoordinateEntry = false

    init(title: String, initialCoordinate: Coordinate, initialName: String, onSelect: @escaping (Coordinate, String?) -> Void) {
        self.title = title
        self.initialCoordinate = initialCoordinate
        self.initialName = initialName
        self.onSelect = onSelect
        _selected = State(initialValue: initialCoordinate)
        _selectedName = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NativeMapView(selected: selected) { coordinate in
                        select(coordinate, name: nil)
                    }
                    .frame(minHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("地点选择地图")
                    .accessibilityHint("轻点或长按以选择位置")
                }

                Section("搜索") {
                    HStack {
                        TextField("城市, 地址或地点", text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { search() }
                            .onChange(of: query) { _, _ in cancelSearch() }
                        if isSearching { ProgressView() }
                    }

                    if let searchError {
                        Text(searchError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    ForEach(results, id: \.self) { item in
                        Button {
                            select(
                                Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude),
                                name: item.name
                            )
                            results = []
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name ?? "未命名地点")
                                if let address = item.placemark.title {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Button("手工输入坐标", systemImage: "number") {
                        showingCoordinateEntry = true
                    }
                }

                Section("已选位置") {
                    LabeledContent("地点", value: selectedName.isEmpty ? selected.label : selectedName)
                    LabeledContent("坐标", value: selected.label)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择") {
                        onSelect(selected, selectedName.isEmpty ? nil : selectedName)
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingCoordinateEntry) {
            CoordinateEntryView { coordinate, name in
                select(coordinate, name: name)
            }
        }
        .onDisappear { cancelSearch() }
    }

    private func select(_ coordinate: Coordinate, name: String?) {
        guard coordinate.isValid else { return }
        selected = coordinate
        selectedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? coordinate.label
    }

    private func search() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        cancelSearch()
        let requestedID = UUID()
        searchID = requestedID
        isSearching = true
        searchError = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery
        let service = MKLocalSearch(request: request)
        localSearch = service
        searchTask = Task { @MainActor in
            defer {
                if searchID == requestedID {
                    isSearching = false
                    localSearch = nil
                }
            }
            do {
                let response = try await service.start()
                guard !Task.isCancelled,
                      searchID == requestedID,
                      query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery else { return }
                results = response.mapItems
                if results.isEmpty { searchError = "没有匹配的地点." }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, searchID == requestedID else { return }
                searchError = "搜索服务暂时不可用, 请稍后重试."
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        localSearch?.cancel()
        searchTask = nil
        localSearch = nil
        searchID = nil
        isSearching = false
        results = []
        searchError = nil
    }
}

private struct WalkingMapView: UIViewRepresentable {
    let route: WalkingRoute?
    let current: Coordinate?
    let start: Coordinate?
    let end: Coordinate?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        context.coordinator.render(route: route, current: current, start: start, end: end, on: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.render(route: route, current: current, start: start, end: end, on: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var renderedGeometry: MapGeometry?

        func render(route: WalkingRoute?, current: Coordinate?, start: Coordinate?, end: Coordinate?, on map: MKMapView) {
            let geometry = MapGeometry(routeCoordinates: route?.coordinates ?? [], start: start, end: end)
            if renderedGeometry != geometry {
                renderedGeometry = geometry
                map.removeOverlays(map.overlays)
                if !geometry.routeCoordinates.isEmpty {
                    var locations = geometry.routeCoordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let polyline = MKPolyline(coordinates: &locations, count: locations.count)
                    map.addOverlay(polyline)
                    map.setVisibleMapRect(polyline.boundingMapRect, edgePadding: UIEdgeInsets(top: 50, left: 35, bottom: 50, right: 35), animated: true)
                } else if let focus = start ?? end {
                    map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude), latitudinalMeters: 1_500, longitudinalMeters: 1_500), animated: false)
                }
            }

            map.removeAnnotations(map.annotations)
            if let start { map.addAnnotation(annotation(start, title: "起点", subtitle: nil)) }
            if let end { map.addAnnotation(annotation(end, title: "终点", subtitle: nil)) }
            if let current { map.addAnnotation(annotation(current, title: "当前位置", subtitle: nil)) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 5
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }

        private func annotation(_ coordinate: Coordinate, title: String, subtitle: String?) -> MKPointAnnotation {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            annotation.title = title
            annotation.subtitle = subtitle
            return annotation
        }

        private struct MapGeometry: Equatable {
            let routeCoordinates: [Coordinate]
            let start: Coordinate?
            let end: Coordinate?
        }
    }
}

private extension MKPolyline {
    var walkingCoordinates: [Coordinate] {
        guard pointCount > 1 else { return [] }
        var locations = Array(repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&locations, range: NSRange(location: 0, length: pointCount))
        return locations.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
