-- name: ListAuthorizedRooms :many
SELECT r.id::text AS id, r.workspace_id::text AS workspace_id, r.title, r.kind,
       r.version, r.scope_epoch, r.stopped
FROM rooms r
JOIN room_members m ON m.room_id=r.id
JOIN principals p ON p.id=m.principal_id
JOIN workspace_members wm ON wm.workspace_id=r.workspace_id AND wm.principal_id=m.principal_id
WHERE m.principal_id=sqlc.arg(principal_id)::uuid AND NOT p.disabled AND r.id>sqlc.arg(after_id)::uuid
ORDER BY r.id LIMIT 101 FOR SHARE OF r,m,p,wm;
