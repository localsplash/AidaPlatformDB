USE echo_db;

-- ─── Carrier lookup ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sms_lkp_Carrier (
  eCarrierId INT PRIMARY KEY,
  carrier VARCHAR(32) NOT NULL,
  description VARCHAR(255)
) ENGINE=InnoDB;

INSERT INTO sms_lkp_Carrier (eCarrierId, carrier, description) VALUES
(1, 'Bandwidth', 'Bandwidth.com voice and messaging'),
(2, 'Twilio',    'Twilio messaging platform'),
(4, 'Sinch',     'Sinch messaging platform'),
(8, 'Tychron',   'Tychron messaging platform')
ON DUPLICATE KEY UPDATE
  carrier     = VALUES(carrier),
  description = VALUES(description);

-- ─── Carrier application ─────────────────────────────────────────────────────
-- A named, reusable set of carrier credentials/config.
-- jsonSettings keys are carrier-specific (e.g. accountId/apiToken for Bandwidth).

CREATE TABLE IF NOT EXISTS sms_tbl_CarrierApplication (
  iCarrierApplicationId BIGINT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  eCarrierId INT NOT NULL,
  jsonSettings JSON NOT NULL,
  dtCreated DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE INDEX uq_carrier_app_name (name),
  CONSTRAINT fk_carrier_app_carrier FOREIGN KEY (eCarrierId) REFERENCES sms_lkp_Carrier(eCarrierId)
) ENGINE=InnoDB;

-- ─── Business phone ───────────────────────────────────────────────────────────
-- iBusinessNumber is the E.164 number as a BIGINT (e.g. 12345556789), and is the PK.

CREATE TABLE IF NOT EXISTS sms_tbl_BusinessPhone (
  iBusinessNumber BIGINT PRIMARY KEY,
  displayName VARCHAR(64),
  iCarrierApplicationId BIGINT NOT NULL,
  dtCreated DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  CONSTRAINT fk_business_phone_carrier_app FOREIGN KEY (iCarrierApplicationId) REFERENCES sms_tbl_CarrierApplication(iCarrierApplicationId)
) ENGINE=InnoDB;

-- ─── Stored procedures ───────────────────────────────────────────────────────

DELIMITER $$

DROP PROCEDURE IF EXISTS sms_usp_CarrierApplication_SET$$
CREATE PROCEDURE sms_usp_CarrierApplication_SET(
  IN p_iCarrierApplicationId BIGINT,
  IN p_name VARCHAR(64),
  IN p_eCarrierId INT,
  IN p_jsonSettings JSON
)
BEGIN
  IF p_iCarrierApplicationId IS NULL THEN
    INSERT INTO sms_tbl_CarrierApplication (name, eCarrierId, jsonSettings)
    VALUES (p_name, p_eCarrierId, p_jsonSettings);

    SELECT LAST_INSERT_ID() AS iCarrierApplicationId;
  ELSE
    UPDATE sms_tbl_CarrierApplication
    SET name         = p_name,
        eCarrierId   = p_eCarrierId,
        jsonSettings = p_jsonSettings
    WHERE iCarrierApplicationId = p_iCarrierApplicationId;

    SELECT p_iCarrierApplicationId AS iCarrierApplicationId;
  END IF;
END$$

DROP PROCEDURE IF EXISTS sms_usp_CarrierApplication_GET$$
CREATE PROCEDURE sms_usp_CarrierApplication_GET(
  IN p_iCarrierApplicationId BIGINT
)
BEGIN
  SELECT
    ca.iCarrierApplicationId,
    ca.name,
    ca.eCarrierId,
    lc.carrier,
    ca.jsonSettings,
    ca.dtCreated
  FROM sms_tbl_CarrierApplication ca
  INNER JOIN sms_lkp_Carrier lc ON lc.eCarrierId = ca.eCarrierId
  WHERE p_iCarrierApplicationId IS NULL
     OR ca.iCarrierApplicationId = p_iCarrierApplicationId
  ORDER BY ca.name;
END$$

DROP PROCEDURE IF EXISTS sms_usp_BusinessPhone_SET$$
CREATE PROCEDURE sms_usp_BusinessPhone_SET(
  IN p_iBusinessNumber BIGINT,
  IN p_displayName VARCHAR(64),
  IN p_iCarrierApplicationId BIGINT
)
BEGIN
  INSERT INTO sms_tbl_BusinessPhone (iBusinessNumber, displayName, iCarrierApplicationId)
  VALUES (p_iBusinessNumber, p_displayName, p_iCarrierApplicationId)
  ON DUPLICATE KEY UPDATE
    displayName           = VALUES(displayName),
    iCarrierApplicationId = VALUES(iCarrierApplicationId);

  SELECT p_iBusinessNumber AS iBusinessNumber;
END$$

DROP PROCEDURE IF EXISTS sms_usp_BusinessPhone_GET$$
CREATE PROCEDURE sms_usp_BusinessPhone_GET(
  IN p_iBusinessNumber BIGINT
)
BEGIN
  -- Returns the business phone record joined with its carrier application and settings.
  -- Pass NULL to retrieve all business phones.
  SELECT
    bp.iBusinessNumber,
    bp.displayName,
    bp.iCarrierApplicationId,
    ca.name           AS carrierApplicationName,
    ca.eCarrierId,
    lc.carrier,
    ca.jsonSettings,
    bp.dtCreated
  FROM sms_tbl_BusinessPhone bp
  INNER JOIN sms_tbl_CarrierApplication ca ON ca.iCarrierApplicationId = bp.iCarrierApplicationId
  INNER JOIN sms_lkp_Carrier lc ON lc.eCarrierId = ca.eCarrierId
  WHERE p_iBusinessNumber IS NULL
     OR bp.iBusinessNumber = p_iBusinessNumber;
END$$

DELIMITER ;
