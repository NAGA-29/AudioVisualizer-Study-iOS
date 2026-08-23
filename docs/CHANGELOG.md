# CHANGELOG

## 2026-08-23

### 追加: 円環スペクトラム (リング) 表示

参考デザイン (円環状に並ぶ発光したバー / 黒背景 / 虹色) を新しい表示モードとして実装した。
判断の経緯は [`docs/adr/0001-radial-spectrum-visual.md`](adr/0001-radial-spectrum-visual.md) に記録。

- `Visual/RadialSpectrumCanvas.swift` (新規)
  - バー値は既存の `SpectrumCanvas.logBars` を再利用し、この型は配置と発光だけを持つ。
  - 半周ぶんのバーを左右対称に鏡像展開 (低域=天頂 / 高域=真下)。配置角は半スロットずらして、
    天頂・真下がバーの隙間に来るようにしている (対称性のため)。
  - バー値で内周を押し出して輪郭をうねらせ、低域エネルギーでリング全体を脈打たせる。
  - 発光は `drawLayer` + `.blur` のレイヤーを 1 枚下に敷いて表現。
- `App/VisualizerSettings.swift`
  - `DisplayMode` に `.radial` を追加。併せて `showsWaveform` / `showsLinearSpectrum` /
    `showsRadialSpectrum` / `prefersDarkBackground` の述語を追加した。
  - リング固有パラメータを `RadialSettings` (バー本数 / 内周半径 / バー長 / 色相の一周量 /
    左右対称 / 回転速度 / 発光量 / 拍の膨らみ) として追加。
- `App/VisualizerScreen.swift`
  - 表示モードの分岐を否定形の比較から述語ベースに変更 (`.radial` 追加で波形が混ざるのを防ぐ)。
  - リング選択時は背景をほぼ黒 (中心にだけ現在色を薄く残す) に切り替える。
  - 回転位相は `TimelineView` の date の剰余から作る (積算しないのでフレーム落ちしてもずれない)。
- `App/TuningSheet.swift`
  - 表示モードの `Picker` から「リング」を選べるようにした。
    4 ラベルではセグメントが潰れるため、既定 (メニュー) のスタイルへ変更。
  - リング選択時のみ「リング」セクションを表示し、上記パラメータを実機で調整できるようにした。
- `AudioVisualizerTests/RadialSpectrumCanvasTests.swift` (新規)
  - 鏡像展開・色相位置の対称性、極座標配置 (向き / 長さ / 回転 / 内周の押し出し)、
    NaN 入力、色相の一周を検証。
- `README.md`: ディレクトリ一覧とチューニング表を更新。

未検証: 実機/シミュレータでのビルドと動作確認 (この作業環境に Xcode がないため)。
