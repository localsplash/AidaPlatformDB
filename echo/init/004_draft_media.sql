USE echo_db;

-- ─── Draft media table ──────────────────────────────────────────────────────
-- Holds attachments a user has picked in the composer but not yet sent.
-- Keyed by (iBusinessNumber, iCustomerNumber) so a draft can be rehydrated
-- when the user returns to a conversation. Rows are removed when the
-- attachment is sent, explicitly removed, or the draft is cleared.

CREATE TABLE IF NOT EXISTS sms_tbl_DraftMedia (
  uidDraftMediaId CHAR(36) PRIMARY KEY,
  iBusinessNumber BIGINT NOT NULL,
  iCustomerNumber BIGINT NOT NULL,
  displayName VARCHAR(255) NOT NULL,
  contentType VARCHAR(128) NOT NULL,
  iContentLength BIGINT NOT NULL DEFAULT 0,
  storagePath VARCHAR(512) NOT NULL,
  thumbnailPath VARCHAR(512),
  dtCreated DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_draftmedia_owner (iBusinessNumber, iCustomerNumber)
) ENGINE=InnoDB;

-- ─── Stored procedures ──────────────────────────────────────────────────────

DELIMITER $$

DROP PROCEDURE IF EXISTS sms_usp_DraftMedia_INS$$
CREATE PROCEDURE sms_usp_DraftMedia_INS(
  IN in_uidDraftMediaId CHAR(36),
  IN in_iBusinessNumber BIGINT,
  IN in_iCustomerNumber BIGINT,
  IN in_displayName VARCHAR(255),
  IN in_contentType VARCHAR(128),
  IN in_iContentLength BIGINT,
  IN in_storagePath VARCHAR(512),
  IN in_thumbnailPath VARCHAR(512)
)
BEGIN
  INSERT INTO sms_tbl_DraftMedia (
    uidDraftMediaId, iBusinessNumber, iCustomerNumber,
    displayName, contentType, iContentLength,
    storagePath, thumbnailPath, dtCreated
  ) VALUES (
    in_uidDraftMediaId, in_iBusinessNumber, in_iCustomerNumber,
    in_displayName, in_contentType, in_iContentLength,
    in_storagePath, in_thumbnailPath, NOW(3)
  );

  SELECT in_uidDraftMediaId AS uidDraftMediaId;
END$$

DROP PROCEDURE IF EXISTS sms_usp_DraftMedia_GET$$
CREATE PROCEDURE sms_usp_DraftMedia_GET(
  IN in_uidDraftMediaId CHAR(36)
)
BEGIN
  SELECT
    uidDraftMediaId,
    iBusinessNumber,
    iCustomerNumber,
    displayName,
    contentType,
    iContentLength,
    storagePath,
    thumbnailPath,
    dtCreated
  FROM sms_tbl_DraftMedia
  WHERE uidDraftMediaId = in_uidDraftMediaId;
END$$

DROP PROCEDURE IF EXISTS sms_usp_DraftMediaByCustomer_GET$$
CREATE PROCEDURE sms_usp_DraftMediaByCustomer_GET(
  IN in_iBusinessNumber BIGINT,
  IN in_iCustomerNumber BIGINT
)
BEGIN
  SELECT
    uidDraftMediaId,
    iBusinessNumber,
    iCustomerNumber,
    displayName,
    contentType,
    iContentLength,
    storagePath,
    thumbnailPath,
    dtCreated
  FROM sms_tbl_DraftMedia
  WHERE iBusinessNumber = in_iBusinessNumber
    AND iCustomerNumber = in_iCustomerNumber
  ORDER BY dtCreated ASC;
END$$

DROP PROCEDURE IF EXISTS sms_usp_DraftMedia_DEL$$
CREATE PROCEDURE sms_usp_DraftMedia_DEL(
  IN in_uidDraftMediaId CHAR(36)
)
BEGIN
  -- Return the pre-delete row so callers can unlink files on disk.
  SELECT
    uidDraftMediaId,
    iBusinessNumber,
    iCustomerNumber,
    displayName,
    contentType,
    iContentLength,
    storagePath,
    thumbnailPath
  FROM sms_tbl_DraftMedia
  WHERE uidDraftMediaId = in_uidDraftMediaId;

  DELETE FROM sms_tbl_DraftMedia
  WHERE uidDraftMediaId = in_uidDraftMediaId;

  SELECT ROW_COUNT() AS deleted;
END$$

DELIMITER ;
