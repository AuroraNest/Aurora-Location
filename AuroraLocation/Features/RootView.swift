import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            FixedLocationView()
                .tabItem { Label("定点定位", systemImage: "location.fill") }

            WalkingView()
                .tabItem { Label("模拟步行", systemImage: "figure.walk") }
        }
        .sheet(isPresented: $state.showSetup) {
            SetupView(state: state)
        }
        .alert("发生错误", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

struct FixedLocationView: View {
    @EnvironmentObject private var state: AppState

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var localSearch: MKLocalSearch?
    @State private var activeSearchID: UUID?
    @State private var geocoder = CLGeocoder()
    @State private var geocodeTask: Task<Void, Never>?
    @State private var showingCoordinateEntry = false
    @State private var showingFavoriteEntry = false
    @State private var favoriteName = ""
    @State private var showingOutdoorHelp = false
    @State private var showingCellularSetup = false
    @AppStorage(CellularShortcut.installedKey) private var cellularInstalled = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NativeMapView(selected: state.selected) { coordinate in
                        select(coordinate)
                    }
                    .frame(minHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("地图")
                    .accessibilityHint("轻点或长按以选择位置. 也可以使用手工输入坐标.")
                    .disabled(isActionBusy)
                }

                Section("搜索") {
                    HStack {
                        TextField("城市, 地址或地点", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { search() }
                            .onChange(of: searchText) { _, _ in cancelSearch() }
                        if isSearching {
                            ProgressView()
                        }
                    }
                    .disabled(isActionBusy)

                    if let searchError {
                        ContentUnavailableView("未找到地点", systemImage: "magnifyingglass", description: Text(searchError))
                    } else {
                        ForEach(searchResults, id: \.self) { item in
                            Button {
                                let coordinate = Coordinate(
                                    latitude: item.placemark.coordinate.latitude,
                                    longitude: item.placemark.coordinate.longitude
                                )
                                select(coordinate, name: item.name)
                                searchResults = []
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
                            .accessibilityHint("选择此搜索结果")
                            .disabled(isActionBusy)
                        }
                    }

                    Button("手工输入坐标", systemImage: "number") {
                        showingCoordinateEntry = true
                    }
                    .disabled(isActionBusy)
                }

                Section("选中位置") {
                    LabeledContent("地点", value: state.selectedName.isEmpty ? "正在识别地址" : state.selectedName)
                    LabeledContent("坐标", value: state.selected.label)

                    Button("收藏此位置", systemImage: "star") {
                        favoriteName = state.selectedName.isEmpty ? state.selected.label : state.selectedName
                        showingFavoriteEntry = true
                    }
                    .disabled(isActionBusy)

                    Button(state.connectionMode == .auroraVPN ? "连接 Aurora VPN 并定位" : "开启模拟定位", systemImage: "location.fill") {
                        execute(.set(state.selected))
                    }
                    .disabled(isActionBusy || state.isWalkingSessionActive)

                    Button(state.isOutdoorPrepared && state.connectionMode == .existing ? "继续蜂窝修改" : "蜂窝修改", systemImage: "antenna.radiowaves.left.and.right") {
                        if state.isOutdoorPrepared && state.connectionMode == .existing {
                            showingOutdoorHelp = true
                        } else if cellularInstalled || state.isSimulating {
                            Task { await state.startAutomaticOutdoor() }
                        } else {
                            showingCellularSetup = true
                        }
                    }
                    .disabled(isActionBusy || state.isWalkingSessionActive)
                    .alert("户外蜂窝修改", isPresented: $showingOutdoorHelp) {
                        Button("取消", role: .cancel) {}
                        Button(state.isOutdoorMode && state.isSimulating ? "修改到选中位置" : state.isOutdoorPrepared ? "已关闭蜂窝, 继续定位" : "蜂窝已开启, 连接本机 VPN") {
                            Task {
                                if state.isOutdoorPrepared || (state.isOutdoorMode && state.isSimulating) {
                                    await state.executeOutdoor()
                                } else {
                                    await state.prepareOutdoor()
                                }
                            }
                        }
                    } message: {
                        Text(state.isOutdoorMode && state.isSimulating
                             ? "当前户外会话可直接换点, 保持小火箭关闭."
                             : state.isOutdoorPrepared
                             ? "本机 VPN 已连接. 现在关闭蜂窝, 保持 Wi-Fi 和小火箭关闭, 再继续定位.\n\n确认位置成功后可恢复蜂窝."
                             : "先选好位置, 关闭 Wi-Fi 和小火箭, 保持蜂窝开启. 先连接本机 VPN, 首次请允许添加配置.\n\n连接后再关闭蜂窝, 回到此处继续定位. 完成并确认位置后可恢复蜂窝, 保持小火箭关闭.")
                    }
                    if state.isOutdoorPrepared && state.connectionMode == .existing {
                        Text("本机 VPN 已准备, 尚未修改位置. 请关闭蜂窝, 再点继续蜂窝修改.")
                            .font(.footnote)
                        Button("取消准备", role: .cancel) {
                            Task { await state.cancelOutdoorPreparation() }
                        }
                        .disabled(isActionBusy)
                    }
                    if state.isOutdoorMode && state.isSimulating {
                        Text(state.connectionMode == .auroraVPN
                             ? "户外会话已建立. 确认定位后可恢复蜂窝. 恢复真实定位后 Aurora VPN 仍保持连接."
                             : "户外会话已建立. 确认定位后可恢复蜂窝, 保持小火箭关闭. 结束请点恢复真实定位.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if state.isWalkingSessionActive {
                        Text("模拟步行进行中. 请切换到模拟步行页面暂停或结束.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if state.needsCellularRecovery && !state.isBusy {
                        Button("恢复蜂窝") {
                            Task { await state.recoverCellular() }
                        }
                    }
                }

                Section("连接状态") {
                    LabeledContent("最近操作", value: state.lastOperation)
                    LabeledContent("Wi-Fi", value: state.wifiAvailable ? "接口有地址" : "未检测到地址")
                    LabeledContent("开发者隧道", value: state.tunnelStatus)
                    LabeledContent("配对", value: state.pairing.status)

                    Button("重新检测", systemImage: "arrow.clockwise") {
                        Task { await state.checkConnection() }
                    }
                    .disabled(isActionBusy)
                }

                savedPlacesSection(title: "收藏", places: state.favorites, delete: state.removeFavorite)
                savedPlacesSection(title: "最近使用", places: state.recents, delete: state.removeRecent)

            }
            .listStyle(.insetGrouped)
            .navigationTitle("Aurora Location")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") { state.showSetup = true }
                }
            }
            .overlay {
                if state.isBusy && !state.isWalkingSessionActive {
                    VStack(spacing: 12) {
                        ProgressView(state.automaticOutdoorStatus ?? "正在处理")
                        if state.canCancelAutomaticOutdoor {
                            Button("取消并恢复蜂窝") { Task { await state.cancelAutomaticOutdoor() } }
                        } else if state.canCancelAuroraVPN {
                            Button("取消连接") { state.cancelAuroraVPNConnection() }
                        }
                    }
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("恢复真实定位", systemImage: "location.slash.fill", role: .destructive) {
                execute(.clear)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .disabled(isActionBusy)
            .accessibilityHint("此操作会请求停止当前模拟定位. 完成前系统定位状态未知.")
            .background(.bar)
        }
        .task {
            state.refresh()
            reverseGeocode(state.selected)
            await state.resumeCellularRecovery()
        }
        .sheet(isPresented: $showingCellularSetup) {
            CellularShortcutSetupView(state: state)
        }
        .sheet(isPresented: $showingCoordinateEntry) {
            CoordinateEntryView { coordinate, name in
                select(coordinate, name: name)
            }
        }
        .alert("收藏位置", isPresented: $showingFavoriteEntry) {
            TextField("名称", text: $favoriteName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                state.addFavorite(name: favoriteName.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private var isActionBusy: Bool { state.isBusy || state.pairing.isBusy }

    @ViewBuilder
    private func savedPlacesSection(title: String, places: [SavedPlace], delete: @escaping (UUID) -> Void) -> some View {
        Section(title) {
            if places.isEmpty {
                Text("暂无位置")
                    .foregroundStyle(.secondary)
            }
            ForEach(places) { place in
                Button {
                    select(place.coordinate, name: place.name)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.name)
                        Text(place.coordinate.label)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isActionBusy)
                .swipeActions {
                    Button("删除", role: .destructive) { delete(place.id) }
                }
            }
        }
    }

    private func select(_ coordinate: Coordinate, name: String? = nil) {
        guard coordinate.isValid else { return }
        geocodeTask?.cancel()
        geocoder.cancelGeocode()
        state.select(coordinate, name: name)
        if name == nil { reverseGeocode(coordinate) }
    }

    private func reverseGeocode(_ coordinate: Coordinate) {
        geocodeTask?.cancel()
        geocoder.cancelGeocode()
        let requestCoordinate = coordinate
        geocodeTask = Task { @MainActor in
            do {
                let placemark = try await geocoder.reverseGeocodeLocation(
                    CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                ).first
                guard !Task.isCancelled, state.selected == requestCoordinate else { return }
                let name = [placemark?.name, placemark?.locality, placemark?.administrativeArea]
                    .compactMap { $0 }
                    .joined(separator: " ")
                if !name.isEmpty { state.select(requestCoordinate, name: name) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, state.selected == requestCoordinate else { return }
                state.select(requestCoordinate, name: requestCoordinate.label)
            }
        }
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        cancelSearch()
        isSearching = true
        searchError = nil
        searchResults = []
        let requestedQuery = query
        let searchID = UUID()
        activeSearchID = searchID
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let service = MKLocalSearch(request: request)
        localSearch = service
        searchTask = Task { @MainActor in
            defer {
                if activeSearchID == searchID {
                    isSearching = false
                    localSearch = nil
                }
            }
            do {
                let response = try await service.start()
                guard !Task.isCancelled,
                      activeSearchID == searchID,
                      searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }
                guard !response.mapItems.isEmpty else {
                    searchError = "没有与 '\(query)' 匹配的城市, 地址或地点."
                    return
                }
                searchResults = response.mapItems
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      activeSearchID == searchID,
                      searchText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }
                searchError = "搜索服务暂时不可用, 请稍后重试."
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        localSearch?.cancel()
        searchTask = nil
        localSearch = nil
        activeSearchID = nil
        isSearching = false
        searchResults = []
        searchError = nil
    }

    private func execute(_ command: LocationCommand) {
        Task { await state.execute(command) }
    }
}

struct CoordinateEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var name = ""
    @State private var error: String?

    let onSelect: (Coordinate, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("坐标") {
                    TextField("纬度, 例如 40.7580", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("经度, 例如 -73.9855", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("名称, 可选", text: $name)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("手工输入坐标")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择") {
                        guard let lat = Double(latitude), let lon = Double(longitude) else {
                            error = "请输入有效的数字."
                            return
                        }
                        let coordinate = Coordinate(latitude: lat, longitude: lon)
                        guard coordinate.isValid else {
                            error = "纬度须在 -90...90, 经度须在 -180...180."
                            return
                        }
                        onSelect(coordinate, name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct NativeMapView: UIViewRepresentable {
    let selected: Coordinate
    let onSelect: (Coordinate) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsCompass = true
        map.showsUserLocation = false
        map.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:))))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didLongPress(_:)))
        map.addGestureRecognizer(longPress)
        context.coordinator.render(selected, on: map, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.render(selected, on: map, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject {
        var onSelect: (Coordinate) -> Void
        private var rendered: Coordinate?

        init(onSelect: @escaping (Coordinate) -> Void) { self.onSelect = onSelect }

        func render(_ coordinate: Coordinate, on map: MKMapView, animated: Bool) {
            guard rendered != coordinate else { return }
            rendered = coordinate
            let location = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            map.removeAnnotations(map.annotations)
            let annotation = MKPointAnnotation()
            annotation.coordinate = location
            annotation.title = "选中位置"
            map.addAnnotation(annotation)
            map.setRegion(MKCoordinateRegion(center: location, latitudinalMeters: 1_500, longitudinalMeters: 1_500), animated: animated)
        }

        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
            select(map.convert(recognizer.location(in: map), toCoordinateFrom: map))
        }

        @objc func didLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map = recognizer.view as? MKMapView else { return }
            select(map.convert(recognizer.location(in: map), toCoordinateFrom: map))
        }

        private func select(_ location: CLLocationCoordinate2D) {
            let coordinate = Coordinate(latitude: location.latitude, longitude: location.longitude)
            guard coordinate.isValid else { return }
            onSelect(coordinate)
        }
    }
}

struct CellularShortcutSetupView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("一次设置, 之后一键修改") {
                    Text(state.connectionMode == .auroraVPN
                         ? "安装 \(CellularShortcut.name)后, App 会自动关闭 Wi-Fi, 打开 Aurora VPN 并等待连接就绪, 临时关闭蜂窝完成定位, 最后重新开启蜂窝."
                         : "安装 \(CellularShortcut.name)后, App 会自动关闭 Wi-Fi, 连接本机 VPN, 临时关闭蜂窝并修改定位, 最后重新开启蜂窝. 首次运行请允许系统提示.")
                    if let url = Bundle.main.url(forResource: "AuroraCellular", withExtension: "shortcut") {
                        ShareLink("安装配套快捷指令", item: url)
                    }
                    Button("已安装, 开始自动修改") {
                        dismiss()
                        Task { await state.startAutomaticOutdoor() }
                    }
                    .disabled(state.isBusy || state.pairing.isBusy)
                }
                if state.connectionMode == .existing {
                Section("手动方式") {
                    Text("关闭 Wi-Fi 和小火箭, 保持蜂窝开启. 连接后关闭蜂窝, 回主页面继续修改.")
                    Button("连接本机 VPN") {
                        dismiss()
                        Task { await state.prepareOutdoor() }
                    }
                    .disabled(state.isBusy || state.pairing.isBusy)
                }
                }
            }
            .navigationTitle("蜂窝修改设置")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
