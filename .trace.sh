#!/usr/bin/env bash
bash -x test_reporting.sh > .trace.txt 2>&1
echo "EXIT=$?"
tail -nn 40 .trace.txt
