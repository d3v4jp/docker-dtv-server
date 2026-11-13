#!/bin/bash
# EPGStation エンコードコマンド: 映像だけを HEVC / H.264 に差し替えた TS を作る
#   - 音声・字幕・番組情報(EIT/SDT)・データ放送は元の TS のまま残るので、
#     KonomiTV は無変換の録画と同じように番組情報を読める
#   - エンコードは Intel iGPU (QSV) か NVIDIA GPU (NVENC) で行う
# EPGStation から環境変数 INPUT / OUTPUT が渡される
#
# 使い方: tsreplace.sh [hevc|h264] [qsv|nvenc]   (省略時は hevc qsv)
#   qsv  : Intel iGPU。ffmpeg の VA-API (Intel Media Driver) 経由でエンコードする
#   nvenc: NVIDIA GPU。ホストに NVIDIA ドライバと NVIDIA Container Toolkit が必要
set -euo pipefail

: "${INPUT:?INPUT is not set}"
: "${OUTPUT:?OUTPUT is not set}"

CODEC="${1:-hevc}"
ENCODER="${2:-qsv}"

# QP は小さいほど高画質・大容量
case "$CODEC" in
  hevc) QP="${HEVC_QP:-25}" ;;   # 目安 23〜28
  h264) QP="${H264_QP:-23}" ;;   # 目安 20〜26 (HEVC より容量は大きくなる)
  *)
    echo "unknown codec: $CODEC (hevc or h264)" >&2
    exit 1
    ;;
esac

case "$ENCODER" in
  qsv|vaapi)
    VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
    HW_OPTS=(-vaapi_device "$VAAPI_DEVICE")
    VF='format=nv12,hwupload,deinterlace_vaapi=rate=frame'
    VOPTS=(-c:v "${CODEC}_vaapi" -rc_mode CQP -qp "$QP")
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

tsreplace -i "$INPUT" -o "$TMP" \
  -e ffmpeg -hide_banner -nostats -loglevel error -y \
     ${HW_OPTS[@]+"${HW_OPTS[@]}"} \
     -f mpegts -i - -copyts -start_at_zero \
     -an -sn -dn \
     -vf "$VF" \
     "${VOPTS[@]}" -g 90 \
     -f mpegts -

mv -f "$TMP" "$OUTPUT"
