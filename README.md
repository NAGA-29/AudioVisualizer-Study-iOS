# AudioVisualizer-Study-iOS

マイク入力から周波数解析を行い、リアルタイムで画面の色と波形を変化させる実験アプリ (iOS 17+ / SwiftUI)。

将来的な ArkEve 関連プロジェクト (Nyx の感覚同期など) における
リアルタイム信号処理パイプラインの基礎検証として位置づけている。

## 前提・制約

- Apple Music など外部アプリの再生ストリームは DRM 保護されており直接タップできない。
  そのため本アプリは **スピーカーから出た音をマイクで拾う** 方式を採る。
- 将来的に自前音源 (`AVAudioPlayerNode`) を直接タップする方式へ切り替えられるよう、
  入力層は `AudioInputSource` プロトコルで抽象化してある (`PlayerTapInputSource` が差し替え先)。
- **実機テスト前提**。シミュレータはマイク入力の挙動 (フォーマット / ゲイン / ルート) が実機と異なる。

## アーキテクチャ

```
[AudioInputSource (protocol)]
   ├─ MicInputSource          : AVAudioEngine + installTap (マイク)
   └─ PlayerTapInputSource    : AVAudioPlayerNode + installTap (将来用)
        ↓ AVAudioPCMBuffer
[AudioAnalyzer]  リングバッファでFFT長ぶん貯めて hop ごとに解析
   ├─ [FFTProcessor]  Accelerate(vDSP) + Hann窓 → magnitude配列
   └─ [BandAnalyzer]  低/中/高域へビン分割・正規化・EMA平滑化・ビート検出
        ↓ BandEnergy { low, mid, high, overall, isBeat }
[ColorMapper]    BandEnergy → HSBColor (Hueの変化速度に上限あり)
        ↓
[VisualizerScreen]  SwiftUI Canvas で波形/スペクトラム + 背景色
```

依存は上から下への一方向。各層は単体で初期化・テストでき、
`FFTProcessor` / `BandAnalyzer` / `ColorMapper` / `SampleRingBuffer` は UI にも AVFoundation にも依存しない。

### スレッド構成

| 処理 | 実行場所 |
| --- | --- |
| `installTap` のコールバック | オーディオスレッド (送出のみ、重い処理は禁止) |
| FFT / 帯域解析 | `VisualizerEngine` が持つ専用 `DispatchQueue` (`.userInitiated`) |
| 状態公開・描画 | MainActor (`@Observable` な `VisualizerEngine`) |

## ディレクトリ

```
AudioVisualizer/
  App/     AudioVisualizerApp, ContentView, VisualizerScreen, TuningSheet,
           VisualizerEngine (パイプラインの結線), VisualizerSettings
  Audio/   AudioInputSource, MicInputSource, PlayerTapInputSource,
           AudioSessionObserver (割り込み/ルート変更), MicrophonePermission
  DSP/     FFTProcessor, BandAnalyzer, BandEnergy, AudioAnalyzer, SampleRingBuffer
  Visual/  ColorMapper, HSBColor, WaveformCanvas, SpectrumCanvas, BandMeterView
AudioVisualizerTests/   FFT / 帯域解析 / 色マッピング / リングバッファの単体テスト
docs/                   実験ノート
```

## セットアップ

1. Xcode 16 以降で `AudioVisualizer.xcodeproj` を開く
   (`objectVersion 77` / file system synchronized group を使っているため Xcode 16+ が必要)。
2. 実機で動かす場合は AudioVisualizer ターゲットの **Signing & Capabilities** で
   Team を設定し、`PRODUCT_BUNDLE_IDENTIFIER` (既定 `com.example.AudioVisualizer`) を自分のものに変更する。
3. iPhone を接続して Run。初回起動時にマイク許可のダイアログが出る。
   - `NSMicrophoneUsageDescription` は Build Settings の
     `INFOPLIST_KEY_NSMicrophoneUsageDescription` で設定済み (Info.plist ファイルは持たない構成)。
4. 音楽を **スピーカー** で再生し、アプリの録音ボタンを押す。

### テスト

```sh
xcodebuild test \
  -project AudioVisualizer.xcodeproj \
  -scheme AudioVisualizer \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

単体テストはマイクを使わない (合成した正弦波と `AVAudioPCMBuffer` を直接流し込む) ので、
シミュレータでそのまま通る。

## 使い方 / チューニング

画面右上のスライダーアイコンからチューニングパネルを開くと、実機で以下を切り替えられる。

| 項目 | 効果 |
| --- | --- |
| FFT サイズ (1024/2048/4096) | 周波数分解能 ↑ / 反応速度 ↓ |
| タップバッファ | `installTap` の粒度。FFT 長とは独立 |
| EMA 係数 | 大きいほど滑らかで鈍い (0.7 前後が出発点) |
| floor / ceiling (dB) | 環境ノイズに合わせた感度調整。生活音が多いなら floor を上げる |
| Hue 変化量/更新 | 色相の最大変化速度。大きいとちらつく |

帯域メーター (画面下部) には low / mid / high / overall の正規化値がそのまま出る。
「色が変わらない」ときに、値が動いていないのか色マッピングが悪いのかを切り分けるためのもの。

## 既知の制約・今後

- 描画は SwiftUI `Canvas` + `TimelineView(.animation)` で 60fps 目安。
  バー数を増やす / パーティクル表現を足す場合は Metal (`MTKView`) への置き換えが必要
  (`VisualizerScreen` にコメントを残してある)。
- バックグラウンドではキャプチャを停止する (バックグラウンド録音はスコープ外)。
- タップのコールバックから Combine の `PassthroughSubject.send` を呼んでいる。
  厳密にはオーディオスレッドでのアロケーション/ロックは real-time safe ではないため、
  グリッチが出るようならロックフリーのリングバッファ + `CADisplayLink` での引き取りに置き換える。
- スコープ外: Apple Music 再生音声への直接アクセス (DRM のため不可能) /
  他ユーザーとのリアルタイム共有 / 音楽ジャンル判定などの ML 処理。

検証観点と結果の記録は [`docs/EXPERIMENT_NOTES.md`](docs/EXPERIMENT_NOTES.md) に置いている。
