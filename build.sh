#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo ">> building ocwd"
v -prod ocwd/ -o /usr/local/bin/ocwd

echo ">> building ocw"
v -prod ocw/ -o /usr/local/bin/ocw

echo ">> building procwd"
v -prod procwd/ -o /usr/local/bin/procwd

echo ">> done"
ls -l /usr/local/bin/ocwd /usr/local/bin/ocw /usr/local/bin/procwd
