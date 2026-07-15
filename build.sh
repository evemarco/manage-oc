#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo ">> building ocd"
v -prod ocd/ -o /usr/local/bin/ocd

echo ">> building oc"
v -prod oc/ -o /usr/local/bin/oc

echo ">> building procwd"
v -prod procwd/ -o /usr/local/bin/procwd

echo ">> done"
ls -l /usr/local/bin/ocd /usr/local/bin/oc /usr/local/bin/procwd
