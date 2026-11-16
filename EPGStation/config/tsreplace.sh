#!/bin/bash
# EPGStation エンコードコマンド: 映像だけを HEVC / H.264 に差し替えた TS を作る
#   - 音声・字幕・番組情報(EIT/SDT)・データ放送は元の TS のまま残るので、
#     KonomiTV は無変換の録画と同じように番組情報を読める
#   - エンコードは Intel iGPU (QSV) か NVIDIA GPU (NVENC) で行う
# EPGStation から環境変数 INPUT / OUTPUT が渡される
# 進捗は {"type":"progress","percent":0〜1,"log":"..."} の形で標準出力に書くと、
# EPGStation のエンコード一覧に進捗バーとして表示される
#
# 使い方: tsreplace.sh [hevc|h264] [qsv|nvenc]   (省略時は hevc qsv)
#   qsv  : Intel iGPU。ffmpeg の VA-API (Intel Media Driver) 経由でエンコードする
#   nvenc: NVIDIA GPU。ホストに NVIDIA ドライバと NVIDIA Container Toolkit が必要
set -euo pipefail

: "${INPUT:?INPUT is not set}"
: "${OUTPUT:?OUTPUT is not set}"

CODEC="${1:-hevc}"
ENCODER="${2:-qsv}"

# 品質値 (NVENC は QP、VA-API の H.264 は QVBR の品質値)。小さいほど高画質・大容量 (VA-API の HEVC は VBR のため使わない)
case "$CODEC" in
  hevc) QP="${HEVC_QP:-23}" ;;   # 目安 20〜24
  h264) QP="${H264_QP:-21}" ;;   # 目安 18〜23 (HEVC より容量は大きくなる)
  *)
    echo "unknown codec: $CODEC (hevc or h264)" >&2
    exit 1
    ;;
esac

# 番組の長さ (秒)。取れないときは進捗を出さず、ビットレートも下の固定値のままエンコードする
DURATION="$("${FFPROBE:-ffprobe}" -v error -show_entries format=duration -of csv=p=0 "$INPUT" 2>/dev/null || true)"

# 元の TS の容量 (圧縮率と、元のビットレートの計算に使う)
IN_BYTES="$(stat -c %s "$INPUT" 2>/dev/null || echo 0)"

# 元の TS 全体 (映像 + 音声 + データ放送) のビットレート [kbps] = 容量 / 番組の長さ。求められないときは 0
SRC_KBPS="$(awk -v b="$IN_BYTES" -v d="$DURATION" 'BEGIN { if (b + 0 > 0 && d + 0 > 0) printf "%d", b * 8 / d / 1000; else print 0 }')"

# 目標ビットレートを「設定値」と「元のビットレート × 割合」の小さいほうにする (VA-API)
#   地デジや BS は元が 15Mbps 前後あるので設定値のまま。元が 7〜8Mbps の CS などは、
#   設定値のままだとほとんど縮まないので、元のビットレートに合わせて下げる
#   割合は元の TS 全体に対する映像の目標 [%]。H.264 は HEVC より圧縮効率が低いので高めにする
HEVC_RATIO="${HEVC_RATIO:-60}"
H264_RATIO="${H264_RATIO:-80}"
MIN_KBPS="${MIN_KBPS:-1500}"   # これより下には下げない (番組の長さを読み違えたときの保険)
rate_opts() {   # rate_opts <目標の設定値 kbps> <上限の設定値 kbps> <割合 %>  → RATE_OPTS に入れる
  local tgt="$1" max="$2" pct="$3" t="$1"
  if [ "$SRC_KBPS" -gt 0 ]; then
    t=$(( SRC_KBPS * pct / 100 ))
    if [ "$t" -gt "$tgt" ]; then t="$tgt"; fi
    if [ "$t" -lt "$MIN_KBPS" ]; then t="$MIN_KBPS"; fi
  fi
  # 上限は、目標との比を設定値と同じに保つ。バッファは上限の 2 秒分
  max=$(( max * t / tgt ))
  RATE_OPTS=(-b:v "${t}k" -maxrate "${max}k" -bufsize "$(( max * 2 ))k")
  echo "bitrate: source ${SRC_KBPS}k -> target ${t}k / max ${max}k (preset ${tgt}k, ${pct}%)" >&2
}

case "$ENCODER" in
  qsv|vaapi)
    VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
    HW_OPTS=(-vaapi_device "$VAAPI_DEVICE")
    VF='format=nv12,hwupload,deinterlace_vaapi=rate=frame'
    # コーデックと映像の幅で設定を分ける (1920: BS などのフルHD / それ以外: 地デジなど)
    # rate_opts の引数は、目標と上限の設定値 [kbps]。元のビットレートが低い番組では自動で下がる
    WIDTH="$("${FFPROBE:-ffprobe}" -v error -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 "$INPUT" 2>/dev/null | head -n 1 || true)"
    case "$CODEC" in
      hevc)
        if [ "${WIDTH:-0}" -ge 1920 ]; then
          # BS/CS (1920x1080)
          rate_opts 8000 12000 "$HEVC_RATIO"
          VOPTS=(-c:v hevc_vaapi -rc_mode VBR "${RATE_OPTS[@]}" -compression_level 4 -bf 2)
        else
          # GR (地デジ 1440x1080。1440x1080 の BS/CS もこちら)
          rate_opts 6000 9000 "$HEVC_RATIO"
          VOPTS=(-c:v hevc_vaapi -rc_mode VBR "${RATE_OPTS[@]}" -compression_level 4 -bf 2)
        fi
        ;;
      h264)
        if [ "${WIDTH:-0}" -ge 1920 ]; then
          # BS/CS (1920x1080)
          rate_opts 11000 14000 "$H264_RATIO"
          VOPTS=(-c:v h264_vaapi -rc_mode QVBR -global_quality "$QP" "${RATE_OPTS[@]}" -compression_level 4 -bf 2)
        else
          # GR (地デジ 1440x1080。1440x1080 の BS/CS もこちら)
          rate_opts 8000 10000 "$H264_RATIO"
          VOPTS=(-c:v h264_vaapi -rc_mode QVBR -global_quality "$QP" "${RATE_OPTS[@]}" -compression_level 4 -bf 2)
        fi
        ;;
    esac
    ;;
  nvenc)
    HW_OPTS=()
    # インターレース解除は CPU (yadif) で行い、エンコードだけ GPU に任せる
    VF='yadif=mode=send_frame:parity=auto:deint=interlaced,format=yuv420p'
    VOPTS=(-c:v "${CODEC}_nvenc" -preset p5 -rc constqp -qp "$QP")
    # Pascal 世代 (Quadro P620 など) は HEVC の B フレームに対応していない
    if [ "$CODEC" = hevc ]; then VOPTS+=(-bf 0); fi
    ;;
  *)
    echo "unknown encoder: $ENCODER (qsv or nvenc)" >&2
    exit 1
    ;;
esac

# 書き込み途中のファイルを KonomiTV に拾わせないよう、別名で書いてから最後に改名する
TMP="${OUTPUT}.part"
trap 'rm -f "$TMP"' ERR INT TERM

# ffmpeg の標準出力は tsreplace への受け渡しに使うので、進捗は -progress でファイルに書かせる
PROG="$(mktemp /tmp/tsreplace-progress.XXXXXX)"
REPORTER=""
cleanup() {
  if [ -n "$REPORTER" ]; then kill "$REPORTER" 2>/dev/null || true; fi
  rm -f "$PROG"
}
trap cleanup EXIT

# 2 秒ごとに -progress の最新値を読み、EPGStation 向けの進捗 JSON を 1 行書く
# log の例: ETR:20m12s 1.95x CR:53%(3.3/6.2GB)
#   (画面では EPGStation が percent から作った「28%」が先頭に付き、
#    「28% ETR:20m12s 1.95x CR:53%(3.3/6.2GB)」と表示される)
#   ETR  : 推定残り時間 (分m秒s。分は桁数を固定しない)。(番組の長さ - 処理済みの時間) / speed で求める
#   speed: 等速 (番組の長さと同じ時間) に対して何倍の速さでエンコードしているか
#   CR   : 圧縮率 = 出力の推定最終容量 / 元の容量。カッコ内は (推定最終容量/元の容量)
#          推定最終容量は「書き出し中の .part の容量 / 進捗」。序盤ほど値がぶれる
# EPGStation は percent を進捗バーと先頭の「nn%」に使うので、log には進捗率を入れない
report_progress() {
  while sleep 2; do
    OUT_BYTES="$(stat -c %s "$TMP" 2>/dev/null || echo 0)"
    awk -F= -v d="$DURATION" -v ib="$IN_BYTES" -v ob="$OUT_BYTES" '
      /^out_time_us=/ { t = $2 }
      /^speed=/       { s = $2 }
      END {
        if (t == "" || t == "N/A" || t + 0 < 0) exit
        p = t / 1000000 / d
        if (p > 1) p = 1
        sp = s + 0
        if (sp > 0) {
          r = int((d - t / 1000000) / sp)
          if (r < 0) r = 0
          msg = sprintf("ETR:%dm%02ds", int(r / 60), r % 60)
          msg = msg sprintf(" %.2fx", sp)
        } else {
          msg = "ETR:--m--s"
        }
        if (p > 0 && ib > 0 && ob > 0) {
          est = ob / p
          msg = msg sprintf(" CR:%d%%(%.1f/%.1fGB)", int(est / ib * 100 + 0.5), est / 1073741824, ib / 1073741824)
        } else {
          msg = msg " CR:--"
        }
        printf "{\"type\":\"progress\",\"percent\":%.4f,\"log\":\"%s\"}\n", p, msg
      }' "$PROG" || true
  done
}
if awk -v d="$DURATION" 'BEGIN { exit !(d + 0 > 0) }'; then
  report_progress &
  REPORTER=$!
fi

tsreplace -i "$INPUT" -o "$TMP" \
  -e ffmpeg -hide_banner -nostats -loglevel error -y \
     -progress "$PROG" \
     ${HW_OPTS[@]+"${HW_OPTS[@]}"} \
     -f mpegts -i - -copyts -start_at_zero \
     -an -sn -dn \
     -vf "$VF" \
     "${VOPTS[@]}" -g 90 \
     -f mpegts -

mv -f "$TMP" "$OUTPUT"
