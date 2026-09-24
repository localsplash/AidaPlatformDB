USE echo_db;

-- ─── Message deletion, conversation deletion, and mark-unread ────────────────
--
-- EchoService has called these three since March 2026 (EchoService d7efd64,
-- "feat: add EchoWeb data APIs to EchoService") but they were never carried
-- across when the messaging schema moved into this repo. They exist only in
-- EchoWeb/mysql/init/001_schema.sql — the earlier three-table copy this
-- schema was derived from — so three endpoints have been answering 500:
--
--   DELETE /api/messages/:messageId                 → sms_usp_Message_DEL
--   DELETE /api/conversations/:customer             → sms_usp_Customer_DEL
--   POST   /api/conversations/:customer/mark-unread → sms_usp_MessageReadLatest_SET
--
-- The bodies are as authored in EchoWeb, with one correction, noted at the
-- procedure it applies to.
--
-- Re-runnable: each procedure is dropped and recreated, so applying this to a
-- database that already has them replaces them with these definitions.

DELIMITER $$

DROP PROCEDURE IF EXISTS sms_usp_Message_DEL$$
CREATE PROCEDURE sms_usp_Message_DEL(
  IN p_iMessageID BIGINT
)
BEGIN
  -- Events first, deliberately. fk_event_id has no ON DELETE action, so the
  -- message cannot go while its events remain. Everything else added since
  -- this was written — sms_tbl_Media, sms_tbl_TychronMessagePart — cascades,
  -- so it does not need naming here and this stays correct as tables are
  -- added, provided they cascade too.
  DELETE FROM sms_tbl_MessageEvent WHERE iMessageId = p_iMessageID;
  DELETE FROM sms_tbl_Message WHERE iMessageId = p_iMessageID;
END$$

DROP PROCEDURE IF EXISTS sms_usp_Customer_DEL$$
CREATE PROCEDURE sms_usp_Customer_DEL(
  IN p_iBusinessNumber BIGINT,
  IN p_iCustomerNumber BIGINT
)
BEGIN
  -- Same ordering, across every message in the conversation.
  DELETE e FROM sms_tbl_MessageEvent e
  INNER JOIN sms_tbl_Message m ON m.iMessageId = e.iMessageId
  WHERE m.iBusinessNumber = p_iBusinessNumber
    AND m.iCustomerNumber = p_iCustomerNumber;

  DELETE FROM sms_tbl_Message
  WHERE iBusinessNumber = p_iBusinessNumber
    AND iCustomerNumber = p_iCustomerNumber;
END$$

DROP PROCEDURE IF EXISTS sms_usp_MessageReadLatest_SET$$
CREATE PROCEDURE sms_usp_MessageReadLatest_SET(
  IN p_iBusinessNumber BIGINT,
  IN p_iCustomerNumber BIGINT,
  IN p_bIsRead BOOLEAN
)
BEGIN
  -- CORRECTION to the EchoWeb original: the latest INBOUND message, not
  -- simply the latest.
  --
  -- As authored this took the newest message in the conversation whatever its
  -- direction. But the unread badge counts inbound only — listConversations
  -- sums `bInbound = 1 AND bIsRead = 0` — and markConversationRead likewise
  -- only clears inbound. So whenever the newest message was one the business
  -- sent, which is the common case because you reply last, mark-unread set a
  -- flag nothing reads and the badge stayed at zero: the feature silently did
  -- nothing.
  --
  -- The derived table is required, not decoration: MySQL will not let an
  -- UPDATE select from its own target directly.
  UPDATE sms_tbl_Message
  SET bIsRead = p_bIsRead
  WHERE iMessageId = (
    SELECT iMessageId FROM (
      SELECT iMessageId
      FROM sms_tbl_Message
      WHERE iBusinessNumber = p_iBusinessNumber
        AND iCustomerNumber = p_iCustomerNumber
        AND bInbound = 1
      ORDER BY dtCreated DESC, iMessageId DESC
      LIMIT 1
    ) x
  );
END$$

DELIMITER ;

-- Not addressed here, because SQL cannot: both DEL procedures leave the media
-- FILES on the shared volume. The sms_tbl_Media rows cascade away, so the
-- files become unreferenced rather than merely stale. Unlinking them needs a
-- caller that knows the filesystem — EchoService — and is worth a separate
-- issue.
