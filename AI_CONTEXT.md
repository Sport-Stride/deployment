# Coachify Platform - AI Context

## Quick reference
- 10 Go microservices behind nginx on api.coachify.tn
- Next.js frontend on app.coachify.tn
- MongoDB for all persistence
- Docker Compose in production on a single VPS
- GitHub Actions for CI/CD, ghcr.io for image registry

## Service map
| Service | Port | Responsibility |
|---|---|---|
| identifier-api | 8080 | Auth, JWT issuance |
| notification-api | 8081 | Push/email notifications |
| account-api | 8082 | User profiles, settings |
| chat-api | 8083 | Real-time messaging, unread badge (MongoDB source of truth, Ably delivery) |
| content-api | 8084 | Blog, content management |
| invitation-api | 8085 | Coach-athlete invitations |
| payments-api | 8086 | Flouci payment processing |
| workout-api | 8087 | Workout plans, exercises |
| tracker-api | 8088 | Progress tracking, notification events |
| statistics-api | 8089 | Analytics, aggregations |

### Chat API Unread Badge Endpoints
- `GET /user/unread-count?roomId={id}&userId={id}` — Per-conversation unread count (MongoDB ReadeReceipt collection)
- `GET /user/global-unread-count` (auth required) — Total unread across all conversations (MongoDB aggregation pipeline)

### Unread Badge Architecture
- **MongoDB Source of Truth**: `Conversation.UnreadCounts[recipientID]` tracks count per participant
- **Ably Real-Time Delivery**: Backend publishes to `user:{recipientID}:unread` channel with `{count: N}` payload
- **Tracker Event Carries Count**: Each message notification includes `recipient_unread_count` in Data field for offline fallback
- **Frontend Single Owner**: ChatBadgeContext centralizes all unread state; no other component manages counts
- **Reset Pattern**: Frontend clears local count on conversation open; backend resets on `MarkConversationRead()`

## My development rules
- Every new endpoint follows: validate → authorize → execute → respond
- Errors always return structured JSON with code + message
- No business logic in handlers
- All services follow identical folder structure


## When I ask you to build a feature
1. Read this context first
2. Follow existing patterns exactly — do not introduce new patterns
3. If unsure about a pattern, ask me before writing code
4. Always write the test alongside the implementation


**Phase 5 — Keep it alive**

The `CLAUDE.md` files become stale fast. Add this to your workflow:
```
# After finishing any significant feature, open Copilot Chat and run:

@workspace I just implemented [feature name] in [service name].
Review what I built and suggest any updates needed to the CLAUDE.md 
for this service to reflect the new patterns or changes introduced.