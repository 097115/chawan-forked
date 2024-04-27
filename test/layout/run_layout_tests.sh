#!/bin/sh
if test -z "$CHA_TEST_BIN"
then	test -f ../../cha && CHA_TEST_BIN=../../cha || CHA_TEST_BIN=cha
fi
failed=0
for h in *.html
do	printf '%s\n' "$h"
	expected="$(basename "$h" .html).expected"
	color_expected="$(basename "$h" .html).color.expected"
	if test -f "$expected"
	then	if ! "$CHA_TEST_BIN" -C config.toml "$h" | diff "$expected" -
		then	failed=$(($failed+1))
			printf 'FAIL: %s\n' "$h"
		fi
	elif test -f "$color_expected"
	then	if ! "$CHA_TEST_BIN" -C config.color.toml "$h" | diff "$color_expected" -
		then	failed=$(($failed+1))
			printf 'FAIL: %s\n' "$h"
		fi
	else	printf 'WARNING: expected file not found for %s\n' "$h"
	fi
done
exit "$failed"
