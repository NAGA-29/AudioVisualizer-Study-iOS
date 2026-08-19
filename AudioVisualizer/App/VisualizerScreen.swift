import SwiftUI

/// メイン画面。背景色が帯域エネルギーで変化し、その上に波形/スペクトラムを重ねる。
///
/// - 描画更新は `TimelineView(.animation)` で 60fps 目安。
/// - Canvas でのバー描画が重い場合は Metal (`MTKView` / `MTKView` を包む `UIViewRepresentable`) への
///   置き換えを検討する。バー数を増やす / パーティクルを足す方向に伸ばすなら Metal 前提になる。
struct VisualizerScreen: View {
    @Environment(VisualizerEngine.self) private var engine
    @State private var isShowingTuning = false

    var body: some View {
        ZStack {
            background
            content
            overlay
        }
        .ignoresSafeArea()
        .sheet(isPresented: $isShowingTuning) {
            TuningSheet()
                .environment(engine)
        }
    }

    // MARK: - 背景

    private var background: some View {
        Color(engine.color)
            // 急な色変化を目に痛くしないための最終段のならし。
            // (値そのものの平滑化は BandAnalyzer の EMA、色相の変化制限は ColorMapper 側で行っている)
            .animation(.easeOut(duration: 0.1), value: engine.color)
            .ignoresSafeArea()
    }

    // MARK: - 波形 / スペクトラム

    private var content: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !engine.status.isRunning)) { _ in
            let accent = Color(engine.color.accent)

            VStack(spacing: 24) {
                if engine.settings.displayMode != .spectrum {
                    WaveformCanvas(samples: engine.snapshot.waveform, color: accent)
                        .frame(height: engine.settings.displayMode == .both ? 140 : 260)
                }
                if engine.settings.displayMode != .waveform {
                    SpectrumCanvas(
                        magnitudes: engine.snapshot.magnitudes,
                        sampleRate: engine.snapshot.sampleRate,
                        color: accent
                    )
                    .frame(height: engine.settings.displayMode == .both ? 180 : 300)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - オーバーレイ (操作系)

    private var overlay: some View {
        VStack {
            HStack {
                statusLabel
                Spacer()
                Button {
                    isShowingTuning = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)

            Spacer()

            if engine.settings.showsDiagnostics {
                BandMeterView(energy: engine.snapshot.energy)
                    .padding(12)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
            }

            if engine.isHeadphoneOutputActive {
                Label("イヤホン出力中です。スピーカー再生でないとマイクが音を拾えません。", systemImage: "headphones")
                    .font(.caption)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.horizontal, 20)
            }

            startStopButton
                .padding(.bottom, 48)
                .padding(.top, 16)
        }
        .foregroundStyle(.white)
    }

    private var statusLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusText)
                .font(.caption.weight(.semibold))
            if engine.snapshot.sampleRate > 0 {
                Text("\(Int(engine.snapshot.sampleRate)) Hz / FFT \(engine.snapshot.fftSize)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.3), in: Capsule())
    }

    private var statusText: String {
        switch engine.status {
        case .idle: return "停止中"
        case .running: return "解析中"
        case .permissionDenied: return "マイク未許可"
        case let .failed(message): return "エラー: \(message)"
        }
    }

    private var startStopButton: some View {
        Button {
            Task { await engine.toggle() }
        } label: {
            Image(systemName: engine.status.isRunning ? "stop.fill" : "mic.fill")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 74, height: 74)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
        }
        .accessibilityLabel(engine.status.isRunning ? "解析を停止" : "解析を開始")
    }
}

#Preview {
    VisualizerScreen()
        .environment(VisualizerEngine())
}
