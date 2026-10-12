-- Equipment and all seven outfits share one atomic row per RP character.
-- Wardrobe names and the concurrency revision are additive JSON properties;
-- existing rows without them remain readable and start at revision zero.
CREATE TABLE IF NOT EXISTS open77_character_presentation (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    character_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    equipment_json LONGTEXT NOT NULL,
    wardrobe_json LONGTEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, character_key)
) ENGINE=InnoDB;
