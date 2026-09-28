USE echo_db;

-- ─── Media table ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sms_tbl_Media (
  uidMediaId CHAR(36) PRIMARY KEY,
  iMessageId BIGINT NOT NULL,
  providerId VARCHAR(512) NOT NULL,
  iContentLength BIGINT NOT NULL DEFAULT 0,
  bObtained BOOLEAN NOT NULL DEFAULT 0,
  displayName VARCHAR(255),
  contentType VARCHAR(128),
  storagePath VARCHAR(512),
  thumbnailPath VARCHAR(512),
  dtCreated DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  CONSTRAINT fk_media_message FOREIGN KEY (iMessageId) REFERENCES sms_tbl_Message(iMessageId) ON DELETE CASCADE,
  INDEX idx_media_message (iMessageId),
  INDEX idx_media_pending (bObtained)
) ENGINE=InnoDB;

-- ─── Stored procedures ───────────────────────────────────────────────────────

DELIMITER $$

DROP PROCEDURE IF EXISTS sms_usp_Media_INS$$
CREATE PROCEDURE sms_usp_Media_INS(
  IN uidMediaId CHAR(36),
  IN iMessageId BIGINT,
  IN providerId VARCHAR(512),
  IN iContentLength BIGINT
)
BEGIN
  DECLARE v_displayName VARCHAR(255);

  -- Extract filename from the tail of the provider URI (after last '/')
  SET v_displayName = SUBSTRING_INDEX(providerId, '/', -1);
  IF v_displayName = '' OR v_displayName IS NULL THEN
    SET v_displayName = 'attachment';
  END IF;

  INSERT INTO sms_tbl_Media (
    uidMediaId, iMessageId, providerId, iContentLength, displayName, dtCreated
  ) VALUES (
    uidMediaId, iMessageId, providerId, iContentLength, v_displayName, NOW(3)
  );

  SELECT uidMediaId, v_displayName AS displayName;
END$$

DROP PROCEDURE IF EXISTS sms_usp_Media_SET$$
CREATE PROCEDURE sms_usp_Media_SET(
  IN in_uidMediaId CHAR(36),
  IN in_bObtained BOOLEAN,
  IN in_storagePath VARCHAR(512),
  IN in_contentType VARCHAR(128),
  IN in_thumbnailPath VARCHAR(512)
)
BEGIN
  UPDATE sms_tbl_Media
  SET bObtained     = in_bObtained,
      storagePath   = in_storagePath,
      contentType   = in_contentType,
      thumbnailPath = in_thumbnailPath
  WHERE uidMediaId = in_uidMediaId;

  SELECT ROW_COUNT() AS updated;
END$$

DROP PROCEDURE IF EXISTS sms_usp_MediaByMessage_GET$$
CREATE PROCEDURE sms_usp_MediaByMessage_GET(
  IN in_iMessageId BIGINT
)
BEGIN
  SELECT
    uidMediaId,
    iMessageId,
    iContentLength,
    bObtained,
    displayName,
    contentType,
    storagePath,
    thumbnailPath,
    dtCreated
  FROM sms_tbl_Media
  WHERE iMessageId = in_iMessageId
  ORDER BY dtCreated ASC;
END$$

DROP PROCEDURE IF EXISTS sms_usp_MediaPending_GET$$
CREATE PROCEDURE sms_usp_MediaPending_GET(
  IN in_iMessageId BIGINT
)
BEGIN
  SELECT
    md.uidMediaId,
    md.iMessageId,
    md.providerId,
    md.displayName,
    md.iContentLength,
    m.iBusinessNumber,
    m.iCustomerNumber
  FROM sms_tbl_Media md
  INNER JOIN sms_tbl_Message m ON m.iMessageId = md.iMessageId
  WHERE md.bObtained = 0
    AND (in_iMessageId IS NULL OR md.iMessageId = in_iMessageId)
  ORDER BY md.dtCreated ASC;
END$$

DELIMITER ;
