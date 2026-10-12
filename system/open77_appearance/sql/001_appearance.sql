CREATE TABLE IF NOT EXISTS open77_player_appearances (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    character_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'default',
    schema_version INT UNSIGNED NOT NULL,
    game_build VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    catalog_digest CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
    logical_json LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, character_key),
    CONSTRAINT chk_open77_appearance_schema CHECK (schema_version = 1),
    CONSTRAINT chk_open77_appearance_revision CHECK (revision > 0)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS open77_characters (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    character_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'default',
    character_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    body_family VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    status VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, character_key),
    UNIQUE KEY uq_open77_character_id (character_id),
    CONSTRAINT chk_open77_character_family CHECK (body_family IN ('female', 'male'))
) ENGINE=InnoDB;
