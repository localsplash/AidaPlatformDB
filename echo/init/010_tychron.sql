USE echo_db;

-- ─── Tychron multipart SMS parts ─────────────────────────────────────────────
--
-- Tychron's SMS send response returns the multipart id, but each segment's
-- delivery report references that segment's own part id, and every segment
-- gets its own report. sms_tbl_Message holds one sMessageId per message, so
-- without this mapping a report for anything longer than a single segment —
-- which is most messages — finds nothing to update and is dropped.
--
-- Tychron-specific on purpose: this solves that and nothing else. It is not a
-- general external-id alias table, and no other carrier writes to it.
--
-- Re-runnable. Every statement in this file is safe to apply to a database
-- that already has it.

CREATE TABLE IF NOT EXISTS sms_tbl_TychronMessagePart (
  -- The part id is the key. Tychron treats any non-2xx on a webhook as a
  -- temporary failure and redelivers, so the same part is offered more than
  -- once as a matter of course; making it the PK turns a replay into a no-op
  -- rather than a duplicate row.
  sPartId      VARCHAR(64) CHARACTER SET latin1 COLLATE latin1_general_cs NOT NULL,
  -- The id returned by the send call, which is what sms_tbl_Message.sMessageId
  -- holds. Kept for tracing a message back to its segments.
  sMultipartId VARCHAR(64) CHARACTER SET latin1 COLLATE latin1_general_cs NOT NULL,
  iMessageId   BIGINT NOT NULL,
  dtCreated    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (sPartId),
  INDEX idx_tychron_part_message (iMessageId),
  INDEX idx_tychron_part_multipart (sMultipartId),
  -- Cascade, so sms_usp_Message_DEL and sms_usp_Customer_DEL keep working
  -- without naming this table.
  CONSTRAINT fk_tychron_part_message FOREIGN KEY (iMessageId)
    REFERENCES sms_tbl_Message(iMessageId) ON DELETE CASCADE
) ENGINE=InnoDB;

-- The collation matches sms_tbl_Message.sMessageId: Tychron ids are ULIDs and
-- are case-sensitive, so a case-insensitive key could collide two distinct
-- parts.

-- ─── Stored procedures ───────────────────────────────────────────────────────

DELIMITER $$

DROP PROCEDURE IF EXISTS sms_usp_TychronMessagePart_INS$$
CREATE PROCEDURE sms_usp_TychronMessagePart_INS(
  IN p_iMessageId BIGINT,
  IN p_sMultipartId VARCHAR(64),
  IN p_sPartId VARCHAR(64)
)
BEGIN
  -- Upsert rather than insert: a resend or a replayed send response must not
  -- fail on a part already recorded.
  INSERT INTO sms_tbl_TychronMessagePart (sPartId, sMultipartId, iMessageId)
  VALUES (p_sPartId, p_sMultipartId, p_iMessageId)
  ON DUPLICATE KEY UPDATE
    sMultipartId = VALUES(sMultipartId),
    iMessageId   = VALUES(iMessageId);
END$$

DROP PROCEDURE IF EXISTS sms_usp_TychronMessagePart_GET$$
CREATE PROCEDURE sms_usp_TychronMessagePart_GET(
  IN p_sPartId VARCHAR(64)
)
BEGIN
  -- Returns the parent message's EXTERNAL id. That is the point: it lets the
  -- caller retry sms_usp_MessageEvent_SET unchanged, so a delivery report that
  -- names a part reaches the message by the same route as one that names the
  -- message, and no existing procedure has to know Tychron exists.
  SELECT
    m.sMessageId,
    m.iMessageId,
    p.sMultipartId
  FROM sms_tbl_TychronMessagePart p
  INNER JOIN sms_tbl_Message m ON m.iMessageId = p.iMessageId
  WHERE p.sPartId = p_sPartId
  LIMIT 1;
END$$

DELIMITER ;
