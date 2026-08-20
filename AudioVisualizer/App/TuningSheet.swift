import SwiftUI

/// 実機チューニング用パネル。実験ノートの検証観点をその場で切り替えられるようにしている。
struct TuningSheet: View {
    @Environment(VisualizerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("表示") {
                    Picker("モード", selection: binding(\.displayMode)) {
                        ForEach(VisualizerSettings.DisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("帯域メーターを表示", isOn: binding(\.showsDiagnostics))
                }

                Section {
                    Picker("FFT サイズ", selection: binding(\.fftSize)) {
                        ForEach(VisualizerSettings.availableFFTSizes, id: \.self) { size in
                            Text("\(size)").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("タップバッファ", selection: binding(\.tapBufferSize)) {
                        ForEach(VisualizerSettings.availableTapBufferSizes, id: \.self) { size in
                            Text("\(size)").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("FFT")
                } footer: {
                    Text("FFT サイズは周波数分解能と反応の速さのトレードオフ。大きいほど低域が細かく見えるが、反応は鈍く感じる。")
                }

                Section {
                    slider("EMA 係数", value: binding(\.smoothing), range: 0...0.95, format: "%.2f")
                } header: {
                    Text("平滑化")
                } footer: {
                    Text("smoothed = prev × 係数 + current × (1 − 係数)。大きいほど滑らかで鈍い。0.7 前後から調整する。")
                }

                Section {
                    slider("floor (dB)", value: binding(\.floorDb), range: -100...(-40), format: "%.0f")
                    slider("ceiling (dB)", value: binding(\.ceilingDb), range: -40...0, format: "%.0f")
                    Toggle("ビート検出", isOn: binding(\.isBeatDetectionEnabled))
                } header: {
                    Text("正規化")
                } footer: {
                    Text("生活音の多い環境では floor を上げるとノイズで反応しにくくなる。静かな環境では下げる。")
                }

                Section {
                    slider("Hue 変化量/更新", value: binding(\.maxHueChangePerUpdate), range: 0.002...0.08, format: "%.3f")
                } header: {
                    Text("色")
                } footer: {
                    Text("大きくすると色が機敏に動くがちらつく。小さくすると落ち着くが曲の変化に追従しない。")
                }
            }
            .navigationTitle("チューニング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    // MARK: - Helpers

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    /// `VisualizerEngine` は設定を private(set) で持っているので、UI からはこのブリッジ経由で更新する。
    private func binding<Value>(_ keyPath: WritableKeyPath<VisualizerSettings, Value>) -> Binding<Value> {
        Binding(
            get: { engine.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = engine.settings
                settings[keyPath: keyPath] = newValue
                engine.update(settings: settings)
            }
        )
    }
}

#Preview {
    TuningSheet()
        .environment(VisualizerEngine())
}
