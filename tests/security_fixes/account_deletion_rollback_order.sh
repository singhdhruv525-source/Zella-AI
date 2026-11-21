#!/usr/bin/env bash
# H5 with lane G's rollbacks: while sql/zella_account_deletion.sql is applied its functions use retention_purge_runs, so
# lane G's sql/rollback/zella_retention_purge_rollback.sql refuses (roll the account deletion back first); after this
# file's rollback, lane G's rollbacks run as before.
. "$(dirname "$0")/lib.sh"; fresh_db account_deletion_rb
apply "$REPO/tests/security_fixes/prod_erase_customer.sql" > /dev/null; apply "$REPO/sql/zella_privacy_retention.sql" > /dev/null || { bad "privacy retention first"; finish; }
out=$(apply "$REPO/sql/zella_account_deletion.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/rollback/zella_business_purge_rollback.sql") && ok "lane G's business purge rolls back" || bad "business purge rollback: $out"
out=$(apply "$REPO/sql/rollback/zella_retention_purge_rollback.sql"); [[ "$out" == *"other functions use the purge runs"* ]] && ok "lane G's purge runs rollback refuses while the account deletion uses them" || bad "not refused: $out"
apply "$REPO/sql/rollback/zella_account_deletion_rollback.sql" > /dev/null && ok "the account deletion rolls back first" || bad "account deletion rollback"
out=$(apply "$REPO/sql/rollback/zella_retention_purge_rollback.sql") && ok "then lane G's purge runs rollback goes through" || bad "after: $out"
finish
