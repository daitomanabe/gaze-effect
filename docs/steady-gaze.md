# 正面視線の安定化

2026-09-05。「右側の動画をもっとずっとまっすぐ見ている状態にする」という調整。

- [最新の補正動画](../Assets/examples/video/steady-gaze/gaze-effect-steady-final.mp4)
- [左: 元映像／右: 新しい補正、下段: 目元拡大](../Assets/examples/video/steady-gaze/gaze-effect-steady-final-comparison.mp4)
- [解析表示](../Assets/examples/video/steady-gaze/gaze-effect-steady-final-debug.mp4)
- [元映像・前版・新しい補正の代表時点](../Assets/examples/video/steady-gaze/final-eye-review.jpg)

1280×720、24 fps、361フレーム。個人キャリブレーションなし。音声は元動画からコピーしており、生成・追加していない。

## 変更内容

1. **頭部姿勢の不安定な推定を置換。** 6点の近似3Dモデルから回転まで解いていた処理では、今回の素材で推定yawの範囲が約42.18度に揺れ、補正先も左右に移動していた。顔全体の変換行列から回転を取り出し、カメラ内部行列に合わせて平行移動だけを解く方式へ変更した。最終設定の推定yaw範囲は約2.54度。これは両推定器の出力の比較であり、実際の角度の正解値を測ったものではない。
2. **補正先だけを安定化。** 目幅で正規化した目元座標で、正面を見る目標の小さな変動を減衰させる。描画時には現在の目元座標へ戻すため、顔の移動・拡大・ロールを画面上で固定しない。検出した現在の虹彩位置を強く平均して遅らせる処理は追加していない。
3. **高速な視線移動での追跡遅れを低減。** VIDEO処理とIMAGE処理で同じ361フレームを比較した。VIDEOでは視線が急に変わった瞬間に虹彩位置の遅れが残ったため、既定をフレームごとのIMAGE処理へ変更した。頭部姿勢・補正先・白目の補完には共通処理側の時間的な安定化を使う。
4. **明瞭な開眼時に目標まで補正。** 十分に解析できる目で、品質による補正量の弱まりが元の視線を残さないように調整した。移動量の上限も広げた。閉眼・遮蔽・追跡喪失での抑止と、まぶた内の描画制限は維持した。
5. **学習済み変形の採用条件を厳密化。** 目標から黒目がずれる候補は局所補正へ戻す。動画・静止画・カメラアプリの共通処理に反映した。

顔変換行列の軸変換は[MediaPipe Face Geometryの座標系](https://chuoling.github.io/mediapipe/solutions/face_mesh.html#metric-3d-space)に従う。今回の修正は学習済み目元生成器の新規導入ではない。

## 出力映像を計測した結果

前版は `build/accuracy-v2/gaze-effect-v2-final.mp4`。元フレームID・時刻が一致する361フレームを比較した。出力画像のまぶた内にある主な暗部の重心を測り、目頭・目尻に対する位置を目幅で正規化した。検出に補正先の座標を使っていない。

| 指標 | 前版 | 今回 |
| --- | ---: | ---: |
| 左右の位置の標準偏差、両目平均 | 0.06455 目幅 | 0.01087 目幅 |
| 上下の位置の標準偏差、両目平均 | 0.02111 目幅 | 0.01135 目幅 |
| 左右の位置のばらつきの減少 | — | 約83.2% |
| 上下の位置のばらつきの減少 | — | 約46.2% |
| 補正・計測した眼フレーム | 722 / 722 | 722 / 722 |

頭部姿勢だけを変更しVIDEOを継続した比較では、左右の標準偏差は約0.0222目幅まで減った。IMAGE処理を組み合わせた最終版は約0.0109目幅まで減った。以前の表示で揺れていた補正先と、高速な視線移動の両方に対処している。

[公開用レポートの保存方法](verification/steady-gaze/README.md) / [全計測結果](verification/steady-gaze/stability-final.json) / [生成レポート](verification/steady-gaze/generation-report.json)

この計測は黒目の画像上の位置変動の指標である。まぶたによる遮蔽、まつ毛、反射、ぼけに影響されるため、視線角度の精度や完全な視線固定の保証とは扱わない。大きな補正での白目・虹彩の質感の限界も残る。

## 動作確認

- Pythonチェック19項目が成功。追加した確認は、頭が移動したときに目標を画面上で遅らせないこと、口元の変形で頭部回転を変えないこと。閉眼時の通過、追跡喪失、マスク外の不変性なども継続確認。
- macOSアプリ2種を再ビルドし署名を検証。アプリ同梱の補正本体と動画生成に使用した補正本体のSHA-256が一致。
- push前の再確認で、アプリ内へのPythonキャッシュ作成が署名を無効にする問題を修正。Pythonを `-B` 付きで起動し、カメラの361フレーム処理、Offline Rendererの全動画書き出し、同梱静止画ツールの実行後も両アプリの署名が有効なことを確認した。GUIから再出力した動画のSHA-256も下記の採用版と一致。
- カメラアプリへの録画入力は361/361フレーム成功、リプレイ欠落0。ブリッジ処理の中央値16.57 ms、95%点39.54 ms。物理カメラの撮影遅延ではない。
- 最終動画3種の全ストリームを読み出し、元時刻・フレーム数・音声を確認。fast技術QAは3/3 PASS。
- 圧縮前の出力で、元映像の予測眼球マスク外の変更は0画素。
- 音声内容のSHA-256は元・補正・比較で一致: `4f873b2b6e90f03d5d1be12bbbcc9b8ba8392c4601fde6d2164898010f15352f`。

動きQAはlight/genericで実行。技術整合性・動きの存在・カメラ／局所動きの分離はPASS、全体と時間安定性はWARN、意図適合はINCONCLUSIVE。5.542〜6.333秒に低変化による停止候補が1件ある。該当する20枚の圧縮前フレームはすべて異なり、目元以外の画素はそれぞれの元フレームと完全に一致した。画像の使い回しや全画面のフリーズは確認されず、今回意図した目元の動きの抑制と整合する低変化だが、解析器のWARN自体は保持した。

[技術QA](verification/steady-gaze/technical-qa.md) / [動きQA](verification/steady-gaze/motion-qa.md) / [停止候補区間の確認](verification/steady-gaze/freeze-candidate-check.json) / [アプリ実行記録](verification/steady-gaze/camera-replay-summary.json)

## 再実行

```sh
.venv/bin/python3 scripts/render-gaze-video.py \
  --input Assets/test-video-2.mp4 \
  --output build/steady-gaze/gaze-effect-steady-final.mp4 \
  --comparison --debug-video --keep-frames

.venv/bin/python3 scripts/measure-gaze-stability.py \
  --before build/accuracy-v2/gaze-effect-v2-final.mp4 \
  --before-records build/accuracy-v2/gaze-effect-v2-final.frames.jsonl \
  --after build/steady-gaze/gaze-effect-steady-final.mp4 \
  --after-records build/steady-gaze/gaze-effect-steady-final.frames.jsonl \
  --output build/steady-gaze/stability-final.json
```

補正本体のSHA-256: `8be70015d62988d1f21ca506b84a8461200db4f4aacba6654b10de58d1a9fab3`。
補正MP4のSHA-256: `a7c95d4917b4d4290ca5970691dd16d79c45540562e30a2711e5b474119a265b`。

個人補正には目標モデルと解析モードの識別子を追加した。古いモデル用の個人補正は消去せず、自動的に非適用にする。個人補正を使う場合は新しい処理で取得し直す。
