#!/usr/bin/env bash
# Two deliveries of the same provider event at the same moment (run by tests/security/run.sh after billing_test.sql,
# which leaves subscription sub_1 in the database). Usage: billing_concurrency.sh <db>
set -u
DB="$1"; PSQL="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 -d $DB"
CALL="select public.zella_process_billing_event('stripe', 'evt_conc', 'payment_succeeded', 'sub_1', null, 4200, 'usd', 'pi_conc', null, null, null, 'race', now() + interval '2 hours', null)"
OUT=$(mktemp)
# first delivery holds its transaction open for 2 s; the second arrives meanwhile and must wait, then see "duplicate"
( $PSQL -c "begin; $CALL; select pg_sleep(2); commit;" | grep -v '^$' | head -1 > "$OUT" ) &
sleep 0.5
SECOND=$($PSQL -c "$CALL"); wait
FIRST=$(cat "$OUT"); rm -f "$OUT"
N=$($PSQL -c "select count(*) from public.payments where external_payment_id = 'pi_conc'")
if [ "$FIRST" = "processed" ] && [ "$SECOND" = "duplicate" ] && [ "$N" = "1" ]; then
  echo "PASS concurrent duplicate delivery: one processed, one duplicate, one payment row"
else
  echo "FAIL concurrent delivery: first=$FIRST second=$SECOND payments=$N"; exit 1
fi
