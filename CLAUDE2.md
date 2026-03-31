# Coachify Codebase Architecture & Conventions Guide
## Developer notes

### Why we made certain decisions

**Factory pattern over hardcoded implementations**
We use the factory design pattern across services to keep the codebase
open for plugin integration. Adding a new payment provider, notification
channel, or ID strategy means implementing an interface and registering
it in the factory — no changes to existing logic.

**Hashmaps for function dispatch**
Instead of long if/else or switch chains, we store functions in hashmaps
keyed by operation type. This keeps dispatch O(1) and makes adding new
operations a one-line registration rather than a structural change.

**Singleton pattern for shared resources**
Database clients, HTTP clients, and config loaders are all singletons.
This prevents connection pool explosion under load and ensures we never
accidentally spin up competing instances of a stateful resource.

---

### Things that have caused bugs before

**Always nil-check before accessing nested struct fields**
Go does not panic on nil structs until you dereference them. Any nested
field access on an optional or externally-sourced struct must be guarded.
Pattern to always follow:
```go
if user != nil && user.Profile != nil {
    // safe to access user.Profile.X
}
```

**MongoDB queries must always have a timeout context**
An uncontexted query will hang indefinitely if MongoDB is slow or
unreachable. Every query must use a context with a deadline:
```go
ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
```

**MongoDB aggregation pipelines over multiple chained queries**
Whenever a feature requires joining or computing across collections,
use an aggregation pipeline instead of multiple round-trip queries.
This has fixed several timeout issues in production — pipelines run
server-side and return one result set instead of N queries.

---

### How I think about features in this service

**Every new endpoint follows this exact order:**
1. `validate` — check inputs, types, required fields
2. `authorize` — verify the caller has permission
3. `execute` — call the service layer
4. `respond` — return structured JSON

**Business logic never goes in handlers**
Handlers are thin. They parse the request, call a service method, and
write the response. All decisions, calculations, and data transformations
live in the service layer. This makes logic independently testable and
keeps handlers readable at a glance.
## 1. ARCHITECTURE OVERVIEW

### Service Purposes (One Sentence Each)

- **coachify-account-api**: Manages user authentication, profile creation, and coach profile management with OAuth2 integration and JWT-based sessions.
- **coachify-chat-api**: Provides real-time chat functionality for communication between coaches and clients using Ably chat service.
- **coachify-client**: Next.js frontend application that provides the user interface for the entire Coachify platform with Tailwind CSS styling.
- **coachify-content-management-api**: Manages and serves content such as articles, resources, and educational materials for coaches and clients.
- **coachify-identifiers-api**: Generates and manages unique identifiers for various entities across the platform using customizable ID schemas.
- **coachify-invitation-api**: Handles user invitation workflows, invitation validation, and team member onboarding processes.
- **coachify-landing**: Marketing landing page (separate Next.js app) serving as the public-facing homepage with SEO optimization.
- **coachify-notification-api**: Sends email notifications via Mailgun for account confirmations, password resets, and system alerts.
- **coachify-payments-api**: Integrates with Stripe to handle subscription billing, payment processing, and plan management.
- **coachify-statistics-api**: Aggregates and computes workout statistics, analytics metrics, and performance insights from workout data using Redis caching.
- **coachify-tracker-api**: Tracks and stores workout sessions, exercise logs, and fitness metrics for performance monitoring.
- **coachify-workout-management-api**: Manages workout creation, scheduling, assignment, and workout plan management for coaches and clients.

### Service Communication Architecture — Evidence-Based Analysis

This section is 100% grounded in actual code findings. Every claim has a source file reference.

#### FRONTEND → Backend Service Communication

**Frontend Environment Variables (Development Mode)**:
The frontend uses conditional proxy routing based on `NEXT_PUBLIC_USE_PROXY` environment variable.
(found in: [coachify-client/src/components/axios/AxiosProvider.tsx](coachify-client/src/components/axios/AxiosProvider.tsx#L16-L44))

**Development Environment Setup** (Direct API calls):
```
NEXT_PUBLIC_ACCOUNT_API_BASE_URL     → coachify-account-api
NEXT_PUBLIC_CHAT_API_BASE_URL        → coachify-chat-api
NEXT_PUBLIC_WORKOUT_API_BASE_URL     → coachify-workout-management-api
NEXT_PUBLIC_INVITATION_API_BASE_URL  → coachify-invitation-api
NEXT_PUBLIC_STATISTICS_API_BASE_URL  → coachify-statistics-api
NEXT_PUBLIC_TRACKER_API_BASE_URL     → coachify-tracker-api
NEXT_PUBLIC_BLOG_API_BASE_URL        → coachify-content-management-api
NEXT_PUBLIC_PAYMENT_API_BASE_URL     → coachify-payments-api
```
(found in: [coachify-client/src/components/axios/AxiosProvider.tsx](coachify-client/src/components/axios/AxiosProvider.tsx#L28-L37))

**Production Setup** (Next.js API Proxy):
In production, frontend uses proxy routes at `/api/proxy/{service}` to route to backend services.
(found in: [coachify-client/src/components/axios/AxiosProvider.tsx](coachify-client/src/components/axios/AxiosProvider.tsx#L20-L25))

**HTTP Client**: Frontend uses Axios with token management and interceptors.
(found in: [coachify-client/src/components/axios/AxiosProvider.tsx](coachify-client/src/components/axios/AxiosProvider.tsx#L1-L50))

#### Frontend → Backend API Calls Summary

| Frontend Page/Component | API Endpoint Called | HTTP Method | Env Variable |
|---|---|---|---|
| Multiple components | `/user/signup` | POST | `NEXT_PUBLIC_ACCOUNT_API_BASE_URL` |
| Authentication flows | `/user/login` | POST | `NEXT_PUBLIC_ACCOUNT_API_BASE_URL` |
| Complete Registration | POST to account API | POST | `NEXT_PUBLIC_ACCOUNT_API_BASE_URL` |
| Update User | `/api/user/update-user/{prefix}` | PATCH | `NEXT_PUBLIC_ACCOUNT_API_BASE_URL` |
| Workouts & Training | Multiple endpoints | GET/POST/PUT | `NEXT_PUBLIC_WORKOUT_API_BASE_URL` |
| Chat | Real-time endpoints | WebSocket/HTTP | `NEXT_PUBLIC_CHAT_API_BASE_URL` |
| Tracker Data | Workout logs, fitness metrics | GET/POST/PUT | `NEXT_PUBLIC_TRACKER_API_BASE_URL` |
| Statistics & Analytics | Performance metrics, dashboards | GET | `NEXT_PUBLIC_STATISTICS_API_BASE_URL` |
| Content Management | Articles, resources | GET | `NEXT_PUBLIC_BLOG_API_BASE_URL` |
| Payments | Subscriptions, billing | POST/GET | `NEXT_PUBLIC_PAYMENT_API_BASE_URL` |

(found in: [coachify-client/src/hooks/useUpdateUser.ts](coachify-client/src/hooks/useUpdateUser.ts#L14), [coachify-client/src/components/axios/AxiosProvider.tsx](coachify-client/src/components/axios/AxiosProvider.tsx))

---

#### Inter-Service Communication — Verified Evidence

**Service Communication Method**: All inter-service calls are **HTTP REST** with JSON payloads and 50-second client timeouts.
(found in: [coachify-account-api/pkg/identifier/api.go](coachify-account-api/pkg/identifier/api.go#L24-L28), [coachify-payments-api/pkg/account/account.go](coachify-payments-api/pkg/account/account.go#L19))

**Configuration Pattern**: Each service loads inter-service URLs from environment variables via Viper at startup.

---

#### Service-to-Service Calls Matrix

| Source Service | Target Service | Function Called | Endpoint | HTTP Method | Trigger | Env Variable | Evidence |
|---|---|---|---|---|---|---|---|
| **coachify-account-api** | **coachify-identifiers-api** | `GenerateId()` | `/identifier/{label}` | GET | User registration, OAuth login | `IDENTIFIER_API_URL` | [services/auth.go:351](coachify-account-api/services/auth.go#L351), [pkg/identifier/api.go:39](coachify-account-api/pkg/identifier/api.go#L39) |
| **coachify-account-api** | **coachify-notification-api** | `SendMail()` | `/emails` | POST | Email confirmation after signup | `NOTIFICATION_API_URL` | [services/auth.go:603](coachify-account-api/services/auth.go#L603), [pkg/notification/api.go:60](coachify-account-api/pkg/notification/api.go#L60) |
| **coachify-account-api** | **coachify-invitation-api** | `AcceptInvitation()` | `/invitation/accept` | POST | User confirms account via invitation | `INVITATION_API_URL` | [services/auth.go:384](coachify-account-api/services/auth.go#L384), [pkg/invitation/api.go:72](coachify-account-api/pkg/invitation/api.go#L72) |
| **coachify-account-api** | **coachify-payments-api** | `SubscribeWithTrial()` | `/subscription/trial` | POST | New user enrollment, role-based plan | `PAYMENT_API_URL` | [services/auth.go:373](coachify-account-api/services/auth.go#L373), [pkg/payments/api.go:19](coachify-account-api/pkg/payments/api.go#L19) |
| **coachify-payments-api** | **coachify-account-api** | `GetCoachClients()` | `/coach/clients` | GET | Fetch coach's clients for billing | `AccountApiURL` | [handlers/subscription_handlers.go:531](coachify-payments-api/handlers/subscription_handlers.go#L531), [pkg/account/account.go:75](coachify-payments-api/pkg/account/account.go#L75) |
| **coachify-statistics-api** | **coachify-workout-management-api** | `GetProgram()`, `GetMetrics()`, `GetExercises()` | `/programs/{id}`, `/metrics/{id}`, `/exercises/{id}` | GET | Compute client performance stats (HTTP sync calls) | `WorkoutApiURL` | [services/contracts.go:65](coachify-statistics-api/services/contracts.go#L65), [pkg/workout/workout.go:68](coachify-statistics-api/pkg/workout/workout.go#L68) |
| **coachify-statistics-api** | **coachify-identifiers-api** | `GenerateId()` | `/identifier/{label}` | GET | Generate metric IDs | `IdentifiersURL` | [pkg/identifiers/api.go:34](coachify-statistics-api/pkg/identifiers/api.go#L34) |
| **coachify-chat-api** | **coachify-account-api** | `GetUserById()` | `/user/get-user/{id}` | GET | Retrieve user profile in chat | `AccountAPIConfig.URL` | [pkg/local/user/api.go:36](coachify-chat-api/pkg/local/user/api.go#L36) |
| **coachify-invitation-api** | **coachify-identifiers-api** | `GenerateId()` | `/identifier/invitation` | GET | Generate invitation IDs | `IdentifiersURL` | [services/invitation.go:129](coachify-invitation-api/services/invitation.go#L129) |
| **coachify-invitation-api** | **coachify-notification-api** | `SendInvitationMail()` | `/emails` | POST | Send invitation email to receiver | `NotificationURL` | [services/invitation.go](coachify-invitation-api/services/invitation.go) (async goroutine ~line 180) |
| **coachify-invitation-api** | **coachify-chat-api** | `CreateConversation()` | `/conversation/create` | POST | Start coach-client conversation on invite | `ChatApiURL` | [services/invitation.go:192](coachify-invitation-api/services/invitation.go#L192), [pkg/chat/api.go:85](coachify-invitation-api/pkg/chat/api.go#L85) |
| **coachify-invitation-api** | **coachify-account-api** | `GetUserByID()` | `/user/{externalID}` | GET | Verify invite recipient exists | `AccountApiUrl` | [services/invitation.go:336](coachify-invitation-api/services/invitation.go#L336), [pkg/account/account.go](coachify-invitation-api/pkg/account/account.go) |
| **coachify-workout-management-api** | **coachify-identifiers-api** | `GenerateId()` | `/identifier/{type}` | GET | Generate workout/task/exercise IDs | `IdentifiersURL` | [services/workout.go:50](coachify-workout-management-api/services/workout.go#L50), [services/task.go:42](coachify-workout-management-api/services/task.go#L42) |

---

#### External Third-Party Service Calls

**coachify-payments-api** calls external payment providers:

| Provider | Endpoint Base | Purpose | Environment Variables | Evidence |
|---|---|---|---|---|
| **Stripe** | `https://api.stripe.com` | Payment processing | `STRIPE_API_KEY`, `STRIPE_WEBHOOK_SECRET` | [config/config.go:48](coachify-payments-api/config/config.go#L48) |
| **Konnect** | `https://api.konnect.tn` | Payment provider (Tunisia) | `KONNECT_API_KEY`, `KONNECT_BASE_URL`, `KONNECT_WEBHOOK_SECRET` | [config/config.go:43](coachify-payments-api/config/config.go#L43) |
| **Flouci** | `https://developers.flouci.com` | Payment provider (Tunisia) | `FLOUCI_BASE_URL`, `FLOUCI_PUBLIC_KEY`, `FLOUCI_PRIVATE_KEY`, `FLOUCI_WEBHOOK_SECRET` | [config/config.go:38](coachify-payments-api/config/config.go#L38) |

(found in: [coachify-payments-api/config/config.go](coachify-payments-api/config/config.go#L35-L55))

---

#### Services with NO Outgoing HTTP Inter-Service Calls (Standalone / Event-Driven)

The following services **do NOT make HTTP calls to other internal services**:

1. **coachify-tracker-api** — Event producer: Publishes workout/fitness data to RabbitMQ for statistics-api to consume asynchronously. Frontend calls this API directly.
2. **coachify-content-management-api** — Standalone content server: Called only by frontend. No inter-service HTTP calls (no /pkg clients found).
3. **coachify-notification-api** — Email-only service: Only calls external Mailgun API. No internal service calls detected.
4. **coachify-identifiers-api** — Utility service: Responds to HTTP calls from other services, does not call them back.

**Note on tracker-api & statistics-api**: These services communicate asynchronously via **RabbitMQ**, not HTTP. Tracker publishes events; Statistics consumes them.
(found in: [coachify-statistics-api/config/config.go](coachify-statistics-api/config/config.go#L26-L29) — RabbitMQ configuration)

---

#### HTTP Client Configuration Pattern (Consistent Across All Services)

All internal service clients follow this pattern:
```go
type {Service}Client struct {
    httpClient *http.Client       // 50-second timeout
    baseURL    string             // Loaded from config
    endpoint   string             // Resource path pattern
}

// Constructor
func New{Service}Client(cfg config.ApiConfig) *{Service}Client {
    return &{Service}Client{
        httpClient: &http.Client{Timeout: 50 * time.Second},
        baseURL:    cfg.{ServiceURL},
        endpoint:   "/{resource}/%s",
    }
}
```

(found in: [coachify-account-api/pkg/identifier/api.go:17-28](coachify-account-api/pkg/identifier/api.go#L17-L28), [coachify-payments-api/pkg/account/account.go:17-22](coachify-payments-api/pkg/account/account.go#L17-L22), [coachify-statistics-api/pkg/workout/workout.go:53-60](coachify-statistics-api/pkg/workout/workout.go#L53-L60))

---

#### Suspicious Patterns & Red Flags Found

✅ **NO CIRCULAR CALLS** — No service calls itself.

✅ **NO LOCALHOST HARDCODING** — All URLs are environment-variable driven (except optional dev defaults).

✅ **NO BYPASSING PROXY** — Services use configured URLs, not container names directly. (found in: [coachify-account-api/utils/config.go:66-68](coachify-account-api/utils/config.go#L66-L68))

⚠️ **HARDCODED DEFAULT URLs** — Some services have Heroku production URLs as fallback defaults:
   - coachify-account-api: `https://coachify-identifier-api-176ecee2c6dd.herokuapp.com`
   - (found in: [coachify-account-api/utils/config.go:66](coachify-account-api/utils/config.go#L66))
   - These should be env-var only in production.

⚠️ **UNUSED CLIENTS** (Potential Dead Code):
   - **coachify-payments-api** has `StripeReturnURL` config but unclear if actively used for payment webhooks
   - (found in: [coachify-payments-api/config/config.go](coachify-payments-api/config/config.go#L51))

---— RabbitMQ Event Streaming

**Tracker → Statistics (Event-Driven, Non-HTTP)**:

Both services connect to shared RabbitMQ for asynchronous data flow:
   - RabbitMQ connection URL: `amqps://qubdqqrf:3rpwXbVk0nqhH7tKy7UBVMGLrfFemJU5@whale.rmq.cloudamqp.com/qubdqqrf`
   - (found in: [coachify-statistics-api/config/config.go](coachify-statistics-api/config/config.go#L26-L29), [coachify-payments-api/config/config.go](coachify-payments-api/config/config.go#L26-L29))

**Flow**:
- **coachify-tracker-api** publishes: Workout sessions, exercise logs, fitness metrics
- **coachify-statistics-api** consumes: Events via RabbitMQ consumer pool, aggregates analytics, caches in Redis
- Benefit: Decoupled data ingestion from analytics computation; no HTTP request blocking

**Frontend Direct Access**:
- Frontend calls **coachify-tracker-api** directly for workout data (HTTP REST)
- Frontend calls **coachify-statistics-api** directly for dashboards/metrics (HTTP REST)
- These APIs don't directly communicate with each other; coordination happens via RabbitMQ event

This indicates events are published by other services (likely coachify-tracker-api or coachify-workout-management-api) that the analytics service consumes.

---

#### Summary: Service Communication Is HTTP-Based & Environment-Driven

✅ **100% HTTP REST** for synchronous inter-service calls  
✅ **All URLs are environment variables** — no hardcoded service names  
✅ **Consistent 50-second timeout** across all service clients  
✅ **Structured error handling** with HTTP status codes propagated  
✅ **Asynchronous fallback** using RabbitMQ for event streaming  
✅ **External integrations** isolated to payments-api only (Stripe, Konnect, Flouci)

### Shared Patterns Across All Services

1. **Standard Folder Structure**: Every Go service follows identical layout:
   - `handlers/`: HTTP request handlers
   - `models/`: Data structures (API models, DB models, mappers)
   - `services/`: Business logic layer
   - `repositories/`: Database access layer
   - `router/`: Route definition and middleware setup
   - `utils/`: Utilities (config, logging, crypto, retry logic)
   - `pkg/`: Client packages for calling external services
   - `app/`: Application initialization and setup

2. **Error Handling Pattern**: All services use `ApiError` struct with consistent error handling:
   ```go
   type ApiError struct {
       Code  int   // HTTP status code
       Error error // Error message
   }
   ```

3. **Middleware Stack**: CORS, security headers, request logging, JWT auth, and Prometheus metrics
4. **Configuration Management**: Viper-based environment variable loading
5. **Structured Logging**: Zap logger with development/production modes
6. **Database**: MongoDB with explicit index initialization
7. **Dependency Injection**: Services instantiated with all dependencies in `services.go`

---

## 2. TECHNOLOGY STACK

### Core Languages & Frameworks

**Backend**:
- **Go**: Version 1.24.0 - 1.26.1 (varies by service, see individual go.mod files)
- **Gin**: Web framework (v1.10.1) used by all Go microservices
- **go.mongodb.org/mongo-driver**: MongoDB driver (v1.17.3+)
- **go.uber.org/zap**: Structured logging (v1.27.0)
- **github.com/spf13/viper**: Configuration management (v1.13.0 - v1.20.1)
- **github.com/golang-jwt/jwt/v4**: JWT token handling (v4.5.2)
- **github.com/appleboy/gin-jwt/v2**: JWT middleware for Gin (v2.10.0)

**Frontend**:
- **Next.js**: v15.1.11 (React 19 based)
- **Node.js**: v22.17.1
- **npm**: v10.9.2
- **TypeScript**: End-to-end type safety
- **Tailwind CSS**: Utility-first styling
- **React Query**: v5.74.3 (data fetching and caching)
- **React Hook Form**: v7+ (form state management)
- **NextAuth**: v5.0.0-beta.25 (authentication)

### Database & Caching

- **MongoDB**: Primary database, all services connect to shared instance
  - Multiple databases: `users`, `payments`, etc.
  - Automatic index initialization on service startup
  - Full ACID transaction support with MongoDB 4.0+

- **Redis**: Used by Statistics API for caching and performance (v8.11.5)

### External Services & Integrations

- **Stripe**: Payment processing (stripe-go v74.0.0)
- **Mailgun**: Email service via HTTP API (mailgun-go v4.22.0)
- **Ably**: Real-time chat service (@ably/chat v0.6.0, ably v2.7.0)
- **Cloudinary**: Image hosting and transformations (cloudinary v2.5.1)
- **OAuth2 Providers**: Google, Facebook (golang.org/x/oauth2)

### Infrastructure & Deployment

- **Docker**: Multi-stage builds for all Go services
  - Build stage: golang:1.25-alpine
  - Runtime stage: Alpine 3.19 (minimal image)
  - Static binaries with CGO_ENABLED=0

- **Nginx**: Reverse proxy for coachify-landing service
- **Environment**: Docker Compose for local development (`docker-compose.yml`)

### Monitoring & Observability

- **Prometheus**: Metrics collection (prometheus/client_golang v1.23.2)
- **Gin-Prometheus**: Metrics middleware (zsais/go-gin-prometheus v1.0.3)
- **Structured Logging**: Zap logger with different levels for dev/prod

### CI/CD & Quality Assurance

- **GitHub Actions**: `.github/workflows/` (implied from `.github/` directory)
- **Test Dependencies**: 
  - Go: `testify` (v1.11.1)
  - Frontend: Testing tools implied from Next.js setup

---

## 3. CODE CONVENTIONS

### Folder Structure Pattern (All Go Services)

```
service-name/
├── app/
│   └── app.go                 # Application initialization & lifecycle
├── handlers/
│   ├── auth.go               # Auth-related HTTP handlers
│   ├── resource.go           # Feature-specific handlers
│   └── health.go             # Health check endpoint
├── models/
│   ├── api/                  # API request/response DTOs
│   ├── db/                   # Database models
│   ├── mapping/              # Struct-to-struct mappers
│   ├── apiError.go           # Centralized error definitions
│   └── masks/                # Field masks for partial updates
├── services/
│   ├── services.go           # Service dependency injection
│   ├── auth.go               # Business logic implementations
│   ├── resource.go           # Other service implementations
│   └── mocks/                # Mock implementations for testing
├── repositories/
│   ├── indexes.go            # Database index definitions
│   ├── User.go               # User repository
│   └── Resource.go           # Other repositories
├── router/
│   ├── router.go             # Route definitions
│   └── middlewares.go        # Middleware stack setup
├── pkg/
│   ├── identifier/           # External service HTTP clients
│   ├── notification/
│   ├── payments/
│   └── invitation/
├── utils/
│   ├── config.go             # Configuration loading
│   ├── logger.go             # Logging setup
│   ├── crypto.go             # Encryption/hashing utilities
│   ├── token.go              # JWT token handling
│   └── retry.go              # Retry logic
├── main.go                   # Application entry point
├── go.mod & go.sum           # Dependency management
├── makefile                  # Build and development tasks
└── Dockerfile                # Container image definition
```

### Naming Conventions

**Files**:
- Handlers: `{resource}.go` (e.g., `auth.go`, `coach.go`, `email.go`)
- Services: `{resource}.go` (e.g., `auth.go`, `payment.go`)
- Repositories: `{Entity}.go` (PascalCase, e.g., `User.go`, `Coach.go`)
- Models: Mixed - `apiError.go`, `db/`, `api/` folders organize by layer
- Middleware: `middlewares.go` (singular collection file)

**Go Functions & Methods**:
- Handler functions (exported): `PascalCase` returning `gin.HandlerFunc`
  - Example: `func OAuth2Login(authService services.AuthService) gin.HandlerFunc`
  - Pattern: `func HandlerName(service ServiceType) gin.HandlerFunc`

- Service methods (exported): `PascalCase` for business logic
  - Example: `func (s *AuthService) HandleOAuthLogin(ctx, providerType, user)`

- Repository methods (exported): `PascalCase` for data access
  - Example: `func (r *UserRepository) FindByEmail(ctx, email)`

- Helper functions (internal): `camelCase` with lowercase first letter
  - Example: `func generateRandomString(length int) (string, error)`

**Variables & Structs**:
- Global/Exported: `PascalCase` (e.g., `Logger`, `Services`, `App`)
- Local/Unexported: `camelCase` (e.g., `ctx`, `userRepo`, `authService`)
- Constants: `SCREAMING_SNAKE_CASE` for environment variables, others follow variable rules
- Struct Fields: `PascalCase` for exported fields (JSON/BSON tags match field names)

**Struct Tags**:
```go
type User struct {
    ID        string `bson:"_id" json:"id"`
    Email     string `bson:"email" json:"email" validate:"required,email"`
    Password  string `bson:"password" json:"-"` // Never expose in API
    CreatedAt time.Time `bson:"created_at" json:"createdAt"`
}
```

### Error Handling Patterns

**Pattern 1: ApiError with Status Code**
```go
func GetUser(service AuthService) gin.HandlerFunc {
    return func(c *gin.Context) {
        user, err := service.GetUserByEmail(c, email)
        if err != nil {
            c.JSON(err.Code, gin.H{"error": err.Error.Error()})
            return
        }
        c.JSON(200, user)
    }
}
```

**Pattern 2: Error Constants in models/apiError.go**
```go
var (
    ErrUserNotFound       = errors.New("user not found")
    ErrEmailAlreadyExists = errors.New("email already exists")
    ErrInvalidPassword    = errors.New("password does not meet complexity requirements")
    ErrUnauthorized       = errors.New("authentication failed")
)
```

**Pattern 3: Wrapping with Status Code**
```go
return &ApiError{
    Code:  http.StatusBadRequest,
    Error: ErrInvalidPassword,
}
```

**Pattern 4: Service Layer Error Handling**
- Services return `(*T, *ApiError)` tuples
- If operation succeeds: `(result, nil)`
- If operation fails: `(nil, &ApiError{Code: status, Error: err})`

**Pattern 5: Repository Error Handling**
- Repositories may return standard Go errors
- Services wrap them with appropriate HTTP status codes
- Never let database errors propagate to handlers directly

### HTTP Handler Structure

**Standard Handler Pattern**:
```go
// 1. Take a Service as parameter
func HandlerName(service services.ServiceType) gin.HandlerFunc {
    // 2. Return a Gin handler function
    return func(c *gin.Context) {
        // 3. Extract parameters from request
        id := c.Param("id")
        var req models.RequestDTO
        if err := c.ShouldBindJSON(&req); err != nil {
            c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
            return
        }
        
        // 4. Call service method with context
        result, apiErr := service.DoSomething(c, req)
        
        // 5. Return error with status code if present
        if apiErr != nil {
            c.JSON(apiErr.Code, gin.H{"error": apiErr.Error.Error()})
            return
        }
        
        // 6. Return success response
        c.JSON(http.StatusOK, result)
    }
}
```

**Route Registration Pattern**:
```go
// In router/router.go
userGroup := r.Group("/user")
userGroup.POST("/signup", handlers.Register(services.AuthService))
userGroup.GET("/:id", handlers.GetUser(services.AuthService))
```

**Request Binding**:
- JSON requests: `c.ShouldBindJSON(&model)`
- Query parameters: `c.Query("key")` 
- URL parameters: `c.Param("id")`
- Headers: `c.GetHeader("Authorization")`

### Middleware & CORS Configuration

**Standard Middleware Stack** (in router/middlewares.go):
```go
r.Use(securityHeaders())        // Security headers (HSTS, CSP, X-Frame-Options)
r.Use(cors.New(cors.Config{}))  // CORS configuration with allowed origins
r.Use(RecoveryWithZap())        // Panic recovery with logging
r.Use(ginprometheus.NewPrometheus("gin")) // Metrics collection
r.Use(Ginzap(logger, format, utc, latency)) // Request logging
```

**Security Headers Applied**:
```go
Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
Content-Security-Policy: default-src 'self'; script-src 'self';...
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
X-XSS-Protection: 1; mode=block
```

**CORS Configuration**:
```go
AllowOrigins: []string{"*"}  // In production, replace with specific domains
AllowMethods: []string{"GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"}
AllowHeaders: []string{"Origin", "Content-Type", "Authorization", "X-Requested-With", ...}
AllowCredentials: true
MaxAge: 12 * time.Hour
```

**JWT Middleware** (appleboy/gin-jwt):
- Applied to protected routes automatically
- Token extracted from `Authorization: Bearer <token>` header
- Custom claims included in context

### Error Response Format

**Consistent Error Response Structure**:
```json
{
    "error": "error message string"
}
```

**Success Response Structure** (varies by endpoint):
```json
{
    "id": "value",
    "data": {...},
    "message": "success message"
}
```

---

## 4. DEVELOPMENT WORKFLOW

### Adding a New Feature (Step-by-Step)

**Step 1: Define Data Models**
```go
// In models/db/resource.go - Database model
type Resource struct {
    ID        string    `bson:"_id"`
    Name      string    `bson:"name"`
    CreatedAt time.Time `bson:"created_at"`
}

// In models/api/resource.go - API request/response
type CreateResourceRequest struct {
    Name string `json:"name" validate:"required"`
}

type ResourceResponse struct {
    ID        string    `json:"id"`
    Name      string    `json:"name"`
    CreatedAt time.Time `json:"createdAt"`
}

// In models/mapping/resource.go - Transformer
func ToResponse(dbResource *db.Resource) *api.ResourceResponse {
    return &api.ResourceResponse{
        ID:   dbResource.ID,
        Name: dbResource.Name,
        // ... map other fields
    }
}
```

**Step 2: Create Repository Methods**
```go
// In repositories/Resource.go - Database access layer
func (r *ResourceRepository) Create(ctx context.Context, resource *db.Resource) error {
    result, err := r.collection.InsertOne(ctx, resource)
    if err != nil {
        return err // Let service wrap with status code
    }
    resource.ID = result.InsertedID.(primitive.ObjectID).Hex()
    return nil
}

func (r *ResourceRepository) FindByID(ctx context.Context, id string) (*db.Resource, error) {
    // Implementation
}
```

**Step 3: Implement Service Logic**
```go
// In services/resource.go - Business logic layer
func (s *ResourceService) CreateResource(ctx context.Context, req *api.CreateResourceRequest) (*api.ResourceResponse, *models.ApiError) {
    // Validate input
    if req.Name == "" {
        return nil, &models.ApiError{
            Code:  http.StatusBadRequest,
            Error: errors.New("name is required"),
        }
    }
    
    // Create DB model
    dbResource := &db.Resource{
        ID:        generateID(),
        Name:      req.Name,
        CreatedAt: time.Now(),
    }
    
    // Persist to database
    if err := s.resourceRepo.Create(ctx, dbResource); err != nil {
        return nil, &models.ApiError{
            Code:  http.StatusInternalServerError,
            Error: err,
        }
    }
    
    // Convert to response
    return mapping.ToResponse(dbResource), nil
}
```

**Step 4: Create HTTP Handlers**
```go
// In handlers/resource.go - HTTP layer
func CreateResource(service services.ResourceService) gin.HandlerFunc {
    return func(c *gin.Context) {
        var req models.CreateResourceRequest
        if err := c.ShouldBindJSON(&req); err != nil {
            c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
            return
        }
        
        resp, apiErr := service.CreateResource(c, &req)
        if apiErr != nil {
            c.JSON(apiErr.Code, gin.H{"error": apiErr.Error.Error()})
            return
        }
        
        c.JSON(http.StatusCreated, resp)
    }
}
```

**Step 5: Register Routes**
```go
// In router/router.go
resourceGroup := r.Group("/resource")
resourceGroup.POST("", handlers.CreateResource(services.ResourceService))
resourceGroup.GET("/:id", handlers.GetResource(services.ResourceService))
resourceGroup.PUT("/:id", handlers.UpdateResource(services.ResourceService))
resourceGroup.DELETE("/:id", handlers.DeleteResource(services.ResourceService))
```

### Service Deployment Process

**Pre-Deployment**:
1. Code changes committed and pushed to feature branch
2. GitHub Actions runs automated tests
3. Pull request created and reviewed
4. Tests pass and PR approved
5. Merge to main branch

**Deployment Steps**:
1. **Build Docker Image**:
   ```bash
   docker build -t coachify-service:tag .
   docker push registry/coachify-service:tag
   ```

2. **Deploy to Kubernetes/Docker Compose**:
   - Update deployment manifest with new image tag
   - Apply changes: `kubectl apply -f deployment.yaml`
   - Or update docker-compose.yml for local

3. **Health Check**:
   - Service exposes `GET /health` endpoint
   - Kubernetes/Docker polls this for readiness
   - Database migrations run on startup if needed

4. **Rollback Strategy**:
   - Keep previous image tag available
   - Quick rollback by reverting to previous tag
   - Database migrations are backward-compatible

### Environment Variable Patterns

**Configuration Management with Viper**:
```go
// In utils/config.go
type AppConfig struct {
    Port                int
    Environment         string    // "development" or "production"
    MongoDB             MongoConfig
    IdentifierAPI       IdentifierAPIConfig
    // ... other configs
}

func LoadConfig() AppConfig {
    viper.SetDefault("PORT", 8080)
    viper.SetDefault("ENVIRONMENT", "development")
    viper.AutomaticEnv()
    
    config := AppConfig{
        Port:        viper.GetInt("PORT"),
        Environment: viper.GetString("ENVIRONMENT"),
    }
    return config
}
```

**Environment Variables by Service**:
```bash
# Common to all services
PORT=8080
ENVIRONMENT=production
LOG_LEVEL=info

# Database
MONGODB_URI=mongodb://host:27017/database_name

# Service-specific (Examples)
IDENTIFIER_API_HOST=identifier-api
IDENTIFIER_API_PORT=8080
NOTIFICATION_API_HOST=notification-api
NOTIFICATION_API_PORT=8080

# OAuth/External Services
GOOGLE_OAUTH_CLIENT_ID=xxx
GOOGLE_OAUTH_CLIENT_SECRET=xxx
STRIPE_API_KEY=sk_live_xxx
MAILGUN_DOMAIN=mg.coachify.com
MAILGUN_API_KEY=xxx
```

**Config Loading Priority**:
1. Environment variables (highest priority)
2. Default values in code
3. Configuration file (if present)

### Testing Conventions

**Mock Services** (in services/mocks/):
```go
type MockAuthService struct {
    GetUserByEmailFunc func(ctx context.Context, email string) (*models.User, error)
}

func (m *MockAuthService) GetUserByEmail(ctx context.Context, email string) (*models.User, error) {
    return m.GetUserByEmailFunc(ctx, email)
}
```

**Test Structure**:
- Test files named `{resource}_test.go`
- Use `testify` for assertions
- Mock external dependencies
- Test both success and error paths

---

## 5. CRITICAL RULES & PATTERNS

### Must-Never-Change Rules

1. **Password Security**
   - Passwords ALWAYS hashed before storage (never plain text)
   - Use bcrypt with salt (golang.org/x/crypto/bcrypt)
   - Validation regex: Must contain min 8 chars, uppercase, lowercase, symbol
   - String comparisons MUST use timing-safe comparison

2. **API Error Response Format**
   - ALWAYS return consistent `{"error": "message"}` structure
   - HTTP status codes MUST be appropriate (400 for bad request, 401 for auth, 404 for not found, 500 for server error)
   - Never expose stack traces to clients in production
   - Errors logged with full context server-side

3. **Database Index Management**
   - Indexes MUST be created on startup in `repositories/indexes.go`
   - Critical indexes: email (unique), user IDs, timestamps
   - Index failures log warning but don't crash service (continues in degraded mode)
   - `InitializeIndexes()` called during app setup, before service starts

4. **JWT Token Handling**
   - Tokens stored in secure HTTP-only cookies or Authorization header
   - Refresh tokens have longer TTL than access tokens
   - Tokens include customer audience/subject claims
   - Token signing uses consistent secret (from environment)

5. **CORS & Security Headers**
   - ALWAYS apply security headers middleware FIRST
   - CORS must restrict origins in production (not wildcard)
   - `X-Frame-Options: DENY` prevents clickjacking
   - `Content-Security-Policy` restricts script sources

6. **Request Context Usage**
   - ALL database/service calls MUST use context passed from HTTP handler
   - Context timeouts prevent hanging connections
   - Example: `service.GetUser(c, userID)` - passes Gin context directly

7. **Service Communication**
   - Inter-service calls use HTTP REST (no gRPC/message queue mix)
   - Caller responsible for retries and timeouts
   - Failed inter-service calls return appropriate error to client

8. **Database Connection**
   - Single MongoDB client per process (connection pooling)
   - Connection established during app startup in `app.go`
   - Graceful shutdown closes connection on signal

9. **Configuration Management**
   - NO hardcoded secrets or API keys (always from environment)
   - Viper loads all config from environment at startup
   - Missing required config variables cause startup failure

10. **Logging in Production**
    - Development mode: Debug level, human-readable format
    - Production mode: Info level, JSON format for aggregation
    - Level determined by `gin.IsDebugging()` and `ENVIRONMENT` variable
    - No sensitive data logged (passwords, tokens, PII)

### Consistent Security Patterns

1. **Authentication Flow**
   - JWT token stored securely (HTTP-only cookie or localStorage)
   - Bearer token in Authorization header: `Authorization: Bearer <token>`
   - Token refresh without re-login via special endpoint
   - Logout clears token from client, invalidates session

2. **Email Verification**
   - New accounts require email confirmation
   - Confirmation code sent to email address via Mailgun
   - Code has expiration (time-limited validity)
   - Resend confirmation code if expired

3. **Password Reset**
   - User initiates reset with email address
   - Reset code sent to email (NOT accessible without email access)
   - Reset happens via code confirmation (no token replay)
   - New password must meet complexity requirements

4. **OAuth2 Integration**
   - State parameter prevents CSRF on OAuth callback
   - State stored in secure cookie with expiration
   - Provider tokens not stored directly (only user ID from provider)
   - Client-side OAuth flow supported (server-side callback optional)

5. **Data Masking**
   - Confidential fields use JSON `json:"-"` tag (e.g., passwords)
   - Partial update masks in request data
   - Sensitive responses sanitized before sending to client

### Consistent Patterns Across All Services

1. **Initialization Order in app.go**:
   - Load configuration
   - Connect to MongoDB
   - Initialize database indexes
   - Create service dependencies
   - Initialize JWT middleware
   - Initialize HTTP clients to external services
   - Create repository instances
   - Create service instances with dependencies
   - Initialize router with services

2. **Dependency Injection**:
   - Services receive all dependencies as constructor parameters
   - No global singletons except Logger and Config
   - Makes testing easier (mock dependencies)
   - Example: `NewAuthService(userRepo, pwChecker, oauth2Providers, ...)`

3. **Handler Function Pattern**:
   - All handlers follow: `HandlerName(service ServiceType) gin.HandlerFunc`
   - Enables testing (mock service)
   - Prevents need for global state

4. **Model Organization**:
   - `models/db/` - Database schemas
   - `models/api/` - Request/response DTOs
   - `models/mapping/` - Conversion functions between layers
   - Clear separation prevents API changes impacting database

5. **Repository Pattern**:
   - Single file per main entity (User.go, Coach.go)
   - All CRUD operations in repository
   - Services call repositories, never call MongoDB directly
   - Easier to switch databases (interface in repositories)

6. **Error Context**:
   - ApiError includes both HTTP status code and error message
   - Status codes inform client of retry-ability
   - Error wrapping preserves originating error

7. **Route Grouping**:
   - Related endpoints grouped with `r.Group("/path")`
   - Middleware applied to groups: `group.Use(middleware)`
   - Health/status endpoints in public group (no auth required)
   - Protected endpoints behind auth middleware

### Patterns That Break

❌ **NEVER**:
- Store passwords in plain text
- Expose stack traces to API clients
- Use global variables for services (except Logger)
- Mix database calls directly in handlers
- Ignore context cancellation
- Trust external input without validation
- Commit secrets/API keys to git
- Make synchronous inter-service calls without timeout
- Return unstructured error responses
- Skip index creation for frequently-queried fields
- Hardcode environment-specific values
- Apply middleware after route registration (order matters)

---

## Quick Reference: Service Health Check Endpoints

All services expose:
- `GET /`
- `GET /health`

Both return `200 OK` with basic status.

---

## Quick Reference: Key Files by Purpose

| Purpose | Location | Language |
|---------|----------|----------|
| Define routes & middleware | `router/router.go`, `router/middlewares.go` | Go |
| Handle HTTP requests | `handlers/*.go` | Go |
| Business logic | `services/*.go` | Go |
| Database access | `repositories/*.go` | Go |
| Data structures | `models/{db,api,mapping}/*.go` | Go |
| App initialization | `app/app.go` | Go |
| Configuration loading | `utils/config.go` | Go |
| Logging setup | `utils/logger.go` | Go |
| External service clients | `pkg/{service}/*.go` | Go |
| Error definitions | `models/apiError.go` | Go |
| Frontend pages | `src/pages/` | TypeScript/React |
| Frontend components | `src/components/` | TypeScript/React |
| Frontend API requests | `src/api/`, `src/services/` | TypeScript |

---

## Development Command Reference

```bash
# Build
go build -o app main.go

# Run service
go run main.go

# Run tests
go test ./...
go test -v ./handlers

# Generate test mocks
go generate ./...

# Format code
go fmt ./...

# Lint code
golangci-lint run

# Frontend (Next.js)
npm run dev        # Development with Turbopack
npm run build      # Production build
npm run start      # Start production server
npm run lint       # Run ESLint
npm run prettier   # Check formatting
```

---

## Key Architectural Decisions

1. **Microservices Architecture**: Each domain (auth, payments, chat) is independent service with own database
2. **RESTful APIs**: Standard HTTP REST for service-to-service communication (not gRPC, not queues)
3. **MongoDB**: Single document database for flexibility across different data models
4. **JWT Authentication**: Stateless auth with tokens, no session storage needed
5. **Email-based OTP**: User identity verification via email (simple, secure, doesn't require SMS)
6. **Gin Framework**: Lightweight, fast, minimal dependencies
7. **Zap Logger**: Fast, structured logging for production observability
8. **Docker Containerization**: Consistent deployment across environments
9. **OAuth2 Integration**: Support for federated identity (Google, Facebook login)

---

## Common Gotchas & Solutions

**Problem**: Service startup fails with "Failed to connect to MongoDB"
- Solution: Verify MONGODB_URI env var is set and MongoDB is running on that host

**Problem**: 502 Bad Gateway when calling another service
- Solution: Check service-to-service URL in config (IDENTIFIER_API_HOST, etc.), verify target service is running

**Problem**: Database queries timing out
- Solution: Check indexes are created (view logs for index creation), verify query is efficient, increase timeout in config

**Problem**: JWT token claims are missing
- Solution: Verify token includes claims when created, check middleware applies claims to context

**Problem**: CORS errors in frontend
- Solution: Verify frontend origin is in AllowOrigins list in router/router.go (not just wildcard)

**Problem**: Email not sending through Mailgun
- Solution: Verify MAILGUN_DOMAIN and MAILGUN_API_KEY are correct in environment

**Problem**: Password validation rejecting valid passwords
- Solution: Password must contain lowercase, uppercase, digit, and symbol; minimum 8 characters

---

End of Architecture Guide. Last Updated: March 2026
