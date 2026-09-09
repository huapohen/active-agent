-- +goose Up
ALTER TABLE principals ADD COLUMN profile_version bigint NOT NULL DEFAULT 1 CHECK(profile_version>0);

-- +goose Down
ALTER TABLE principals DROP COLUMN profile_version;
