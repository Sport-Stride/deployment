# Coachify Architecture Diagrams & Interaction Flows

This document contains comprehensive visualizations of the Coachify platform architecture, service interactions, and deployment workflows.

---

## 1. User Signup & Authentication Flow

```mermaid
sequenceDiagram
    participant Browser as 🌐 Browser
    participant Frontend as Frontend<br/>(Next.js)
    participant Nginx as Nginx<br/>(Reverse Proxy)
    participant AccountAPI as account-api<br/>(Auth Service)
    participant IdentifierAPI as identifier-api<br/>(ID Generator)
    participant NotificationAPI as notification-api<br/>(Email)
    participant InvitationAPI as invitation-api<br/>(Onboarding)
    participant PaymentAPI as payments-api<br/>(Billing)
    participant MongoDB as MongoDB<br/>(Local)
    
    Browser->>Frontend: POST /signup
    Frontend->>Nginx: [TLS] → api.coachify.tn/account/signup
    Nginx->>AccountAPI: Route to account-api:8082
    AccountAPI->>IdentifierAPI: GET /identifier/user
    IdentifierAPI->>MongoDB: Insert ID counter
    IdentifierAPI-->>AccountAPI: Return userID
    AccountAPI->>MongoDB: Insert user doc
    AccountAPI->>NotificationAPI: POST /emails (verification code)
    NotificationAPI-->>Browser: ✉️ Verification email sent
    AccountAPI->>InvitationAPI: POST /invitation/accept (if invited)
    InvitationAPI->>PaymentAPI: POST /subscription/trial
    PaymentAPI-->>AccountAPI: ✅ Trial activated
    AccountAPI-->>Frontend: {token, userId, role}
    Frontend-->>Browser: 🎉 Signup complete → Redirect to dashboard
```

**Flow Details:**
- User submits email/password on frontend → Frontend validates → Calls account-api
- account-api requests unique ID from identifier-api
- User document created in MongoDB with hashed password
- Verification email sent via notification-api (Mailgun)
- If invited: initation-api creates chat conversation and payments-api enables trial subscription
- JWT token returned to frontend for subsequent requests

---

## 2. Real-Time Chat & Message Flow (Ably Integration)

```mermaid
sequenceDiagram
    participant Coach as 👨‍🏫 Coach Browser
    participant Client as 👨‍💼 Client Browser
    participant Frontend1 as Coach Frontend<br/>(Ably Client)
    participant Frontend2 as Client Frontend<br/>(Ably Client)
    participant Ably as ☁️ Ably Service<br/>(Real-Time)
    participant ChatAPI as chat-api<br/>(Message Store)
    participant MongoDB as MongoDB
    
    Note over Coach,Client: Both clients connect to Ably with NEXT_PUBLIC_ABLY_KEY
    Coach->>Frontend1: Opens chat conversation
    Frontend1->>Ably: Connect → Create channel "conversation:{id}"
    Client->>Frontend2: Opens same conversation
    Frontend2->>Ably: Connect → Subscribe to channel
    
    Coach->>Frontend1: Types message → Send
    Frontend1->>ChatAPI: POST /message (async logging)
    Frontend1->>Ably: Publish message to channel
    Ably->>Frontend2: Real-time message delivery
    Frontend2->>Client: 💬 Message appears instantly
    ChatAPI->>MongoDB: Store message for history
    
    Client->>Frontend2: Reply message
    Frontend2->>Ably: Publish reply
    Ably->>Frontend1: Real-time delivery to coach
    Frontend1->>Coach: ✅ Reply received
    
    Note over Coach,Client: All messages real-time via Ably (10-50ms latency)
```

**Key Points:**
- Both clients use `NEXT_PUBLIC_ABLY_KEY` for real-time connection
- Ably handles 100% of message delivery (pub/sub model)
- chat-api logs to MongoDB for message history (async)
- Channels named: `conversation:{conversationId}` for isolation
- Connection pooling on Ably side = scalable to 1000+ concurrent users

---

## 3. Workout Tracking & Analytics Pipeline

```mermaid
graph LR
    subgraph "Real-Time Collection"
        TR1["🏃 Tracker API<br/>(8088)"]
        TR2["📊 Workout Session"]
        TR1 -->|POST /session| TR2
    end
    
    subgraph "Event Bus (RabbitMQ)"
        RMQ["☁️ CloudAMQP<br/>RabbitMQ"]
    end
    
    subgraph "Analytics Layer"
        STATS["📈 Statistics API<br/>(8089)"]
        REDIS["⚡ Redis Cache"]
    end
    
    subgraph "Data Storage"
        MONGO["🗄️ MongoDB<br/>coachify DB"]
    end
    
    subgraph "Frontend Display"
        FE["🌐 Frontend<br/>Dashboard"]
    end
    
    TR1 -->|Publish event| RMQ
    RMQ -->|Consume: workout.session.completed| STATS
    STATS -->|Aggregate stats| REDIS
    STATS -->|Query historical| MONGO
    STATS -->|GET /stats/{clientId}| FE
    FE -->|Display performance| FE
    
    style RMQ fill:#ff9999
    style REDIS fill:#99ff99
    style STATS fill:#99ccff
    style MONGO fill:#ffcc99
```

**Async Data Flow:**
1. Client completes workout → Tracker API stores session
2. Tracker publishes event to RabbitMQ: `workout.session.completed`
3. Statistics API consumes event asynchronously
4. Stats aggregated and cached in Redis (30min TTL)
5. Frontend queries `/statistics/performance/{clientId}` → instant Redis response
6. **Result:** Analytics available within 1-2 seconds, non-blocking

---

## 4. Service Dependency Graph

```mermaid
graph TB
    subgraph "Frontend Layer"
        FE["🌐 Frontend<br/>(Next.js 15)"]
    end
    
    subgraph "API Gateway"
        NG["🔐 Nginx<br/>Reverse Proxy<br/>TLS on 443"]
    end
    
    subgraph "Core Services"
        AA["👤 Account API<br/>(8082)"]
        CA["💬 Chat API<br/>(8083)"]
        WA["💪 Workout API<br/>(8084)"]
        TA["📍 Tracker API<br/>(8088)"]
        SA["📈 Statistics API<br/>(8089)"]
    end
    
    subgraph "Supporting Services"
        IA["🔑 Identifier API<br/>(8080)"]
        NA["📧 Notification API<br/>(8081)"]
        PA["💳 Payments API<br/>(8085)"]
        INA["🎫 Invitation API<br/>(8086)"]
        CONT["📚 Content API<br/>(8087)"]
    end
    
    subgraph "External Services"
        ABLY["☁️ Ably<br/>Real-time"]
        STRIPE["💰 Stripe<br/>Payments"]
        MAILGUN["✉️ Mailgun<br/>Email"]
        GOOGLE["🔵 Google<br/>OAuth2"]
    end
    
    subgraph "Data & Cache"
        MONGO["🗄️ MongoDB<br/>Local"]
        RMQ["☁️ RabbitMQ<br/>Events"]
        REDIS["⚡ Redis<br/>Cache"]
    end
    
    FE -->|HTTPS| NG
    NG -->|Routes| AA
    NG -->|Routes| CA
    NG -->|Routes| WA
    NG -->|Routes| SA
    NG -->|Routes| TA
    NG -->|Routes| PA
    NG -->|Routes| INA
    NG -->|Routes| CONT
    
    AA -->|HTTP| IA
    AA -->|HTTP| NA
    AA -->|HTTP| PA
    AA -->|HTTP| INA
    AA -->|OAuth2| GOOGLE
    
    PA -->|HTTP| AA
    PA -->|REST| STRIPE
    
    INA -->|HTTP| CA
    INA -->|HTTP| NA
    
    SA -->|Consume| RMQ
    TA -->|Publish| RMQ
    
    CA -->|HTTP| AA
    
    AA -->|Query| MONGO
    WA -->|Query| MONGO
    TA -->|Query| MONGO
    SA -->|Cache| REDIS
    SA -->|Query| MONGO
    
    CA -->|Real-time| ABLY
    
    NA -->|REST| MAILGUN
    
    style NG fill:#ff6666
    style ABLY fill:#99ff99
    style STRIPE fill:#99ccff
    style RMQ fill:#ffcc99
    style REDIS fill:#ccccff
```

**Service Roles:**
- **Account API**: User auth, profiles, identity management
- **Chat API**: Stores conversations (Ably handles real-time)
- **Workout API**: Program/exercise management
- **Tracker API**: Session logging & event publishing
- **Statistics API**: Analytics aggregation from RabbitMQ
- **Payments API**: Stripe integration & subscriptions
- **Notification API**: Email service (Mailgun)
- **Invitation API**: Onboarding workflows

---

## 5. Deployment Architecture on VPS

```mermaid
graph TB
    subgraph "VPS (54.37.225.78:11GB RAM)"
        subgraph "Docker Network (coachify_net)"
            NG["🔐 Nginx Container<br/>Port 80/443<br/>TLS Termination"]
            FE["🌐 Frontend Container<br/>Port 3000<br/>Next.js"]
            AA["👤 account-api:8082"]
            CA["💬 chat-api:8083"]
            WA["💪 workout-api:8084"]
            PA["💳 payments-api:8085"]
            INA["🎫 invitation-api:8086"]
            CONT["📚 content-api:8087"]
            TA["📍 tracker-api:8088"]
            SA["📈 statistics-api:8089"]
            IA["🔑 identifier-api:8080"]
            NA["📧 notification-api:8081"]
            
            MONGO["🗄️ MongoDB Container<br/>Port 27017<br/>Single Instance"]
            
            REDIS["⚡ Redis Container<br/>Port 6379<br/>Cache"]
        end
        
        subgraph "Host OS"
            SYSLOG["📋 Syslog"]
        end
    end
    
    subgraph "External Cloud"
        RMQ["☁️ CloudAMQP<br/>RabbitMQ"]
        ABLY["☁️ Ably<br/>Real-time"]
        STRIPE["💰 Stripe API"]
        MAILGUN["✉️ Mailgun"]
    end
    
    subgraph "GitHub"
        GH["GitHub Actions<br/>build.yml + deploy.yml"]
    end
    
    subgraph "User Browsers"
        USERS["👥 Users<br/>(HTTPS on 443)"]
    end
    
    USERS -->|app.coachify.tn| NG
    NG -->|DNS: frontend:3000| FE
    NG -->|DNS: account-api:8082| AA
    NG -->|DNS: chat-api:8083| CA
    NG -->|DNS: workout-api:8084| WA
    
    AA -->|Query| MONGO
    CA -->|Query| MONGO
    WA -->|Query| MONGO
    SA -->|Cache| REDIS
    SA -->|Consume| RMQ
    TA -->|Publish| RMQ
    
    AA -->|HTTPS| STRIPE
    NA -->|REST| MAILGUN
    CA -->|Real-time| ABLY
    
    GH -->|Pull images| FE
    GH -->|Pull images| AA
    GH -->|Deploy| NG
    
    style NG fill:#ff6666
    style MONGO fill:#ffcc99
    style REDIS fill:#ccccff
```

**Key Deployment Facts:**
- All services in single Docker bridge network `coachify_net`
- Service discovery via Docker DNS (e.g., `account-api:8082`)
- MongoDB: Single local instance (172.18.0.1:27017 from container perspective)
- Nginx routes by hostname: `app.coachify.tn` → frontend, `api.coachify.tn` → services
- GitHub Actions auto-deploys on push to main
- All environment variables from `.env.production` on VPS

---

## 6. Payment & Subscription Flow

```mermaid
sequenceDiagram
    participant User as 👤 User<br/>(Browser)
    participant Frontend as Frontend<br/>(Next.js)
    participant PaymentAPI as payments-api<br/>(8085)
    participant Stripe as 💳 Stripe API
    participant AccountAPI as account-api<br/>(Auth)
    participant MongoDB as MongoDB
    
    User->>Frontend: Click "Upgrade Plan"
    Frontend->>PaymentAPI: POST /subscription/checkout
    PaymentAPI->>Stripe: Create checkout session
    Stripe-->>Frontend: Session ID + redirect URL
    Frontend-->>User: Redirect to Stripe checkout
    
    User->>Stripe: Enter card details
    Stripe->>Stripe: Process payment
    Stripe-->>User: ✅ Payment success
    Stripe->>PaymentAPI: Webhook: charge.succeeded
    
    PaymentAPI->>AccountAPI: GET /coach/clients (verify role)
    PaymentAPI->>MongoDB: Update subscription status
    PaymentAPI->>MongoDB: Store payment record
    
    PaymentAPI-->>Stripe: Acknowledge webhook
    Frontend->>AccountAPI: GET /user/profile
    AccountAPI->>MongoDB: Query subscription
    Frontend-->>User: 🎉 Premium features unlocked
    
    Note over User,MongoDB: Subscription active for 30 days<br/>Auto-renewal if payment method valid
```

**Payment Integration:**
- Stripe handles PCI compliance (no card data on our servers)
- Webhook verification prevents fraud
- Subscription status stored in user document
- Auto-renewal via Stripe subscriptions API
- Failed payment → webhook triggers downgrade/notification

---

## 7. Coach-Client Invitation & Onboarding

```mermaid
graph TD
    subgraph "Invitation Phase"
        C["👨‍🏫 Coach"]
        C -->|POST /invitation/invite| IV["invitation-api"]
        IV -->|Generate inviteId| IA["identifier-api"]
        IA -->|Create code| IV
        IV -->|Store invite doc| M["MongoDB"]
        IV -->|Send email| NI["notification-api"]
        NI -->|Mailgun| MG["📧 Client Email"]
        MG -->|Click link| CL["👨‍💼 Client"]
    end
    
    subgraph "Acceptance Phase"
        CL -->|POST /invitation/accept| IV2["invitation-api"]
        IV2 -->|Verify inviteId| M
        IV2 -->|Create conversation| CH["chat-api"]
        CH -->|Store conv| M
        IV2 -->|Enable trial| PA["payments-api"]
        PA -->|Create subscription| ST["Stripe"]
    end
    
    subgraph "Active Relationship"
        C -->|Assign workout| WA["workout-api"]
        WA -->|Store program| M
        CL -->|Log workout| TA["tracker-api"]
        TA -->|Publish event| RMQ["RabbitMQ"]
        RMQ -->|Analytics| SA["statistics-api"]
        CL -->|View progress| SA
        C -->|Chat with client| CH
        CL -->|Real-time chat| ABLY["Ably"]
    end
    
    style IV fill:#99ff99
    style PA fill:#ccccff
    style CH fill:#ffcc99
    style TA fill:#ff9999
```

**Onboarding Workflow:**
1. **Coach initiates**: Coach invites client by email
2. **Invitation sent**: invitation-api generates unique code, sends via email
3. **Client accepts**: Client clicks link, confirms account
4. **Relationship created**: Chat conversation auto-created
5. **Trial activated**: payments-api enables 14-day trial
6. **Full access**: Client can now see assigned workouts and chat

---

## 8. System Health & Monitoring

```mermaid
graph TB
    subgraph "Services"
        SVC["10 Go Microservices<br/>+ Frontend<br/>+ Nginx"]
    end
    
    subgraph "Health Checks"
        HC["GET /health<br/>(Every 10s)"]
    end
    
    subgraph "Docker Compose"
        DOCKER["docker ps<br/>docker logs"]
    end
    
    subgraph "Metrics"
        PROM["Prometheus<br/>(Gin middleware)"]
    end
    
    subgraph "Logging"
        ZAP["Zap Logger<br/>(Structured JSON)"]
        LOGS["Deploy logs<br/>(deploy.log)"]
    end
    
    SVC -->|/health| HC
    HC -->|200 OK| DOCKER
    SVC -->|Metrics| PROM
    SVC -->|Logs| ZAP
    DOCKER -->|Restart on fail| SVC
    ZAP -->|Write to| LOGS
    
    style HC fill:#99ff99
    style PROM fill:#ffcc99
    style ZAP fill:#ccccff
```

**Monitoring Approach:**
- Each service exposes `GET /health` endpoint
- Docker Compose health checks restart failed containers
- Prometheus metrics via Gin middleware (p50, p95, p99 latencies)
- Structured logging with Zap (JSON in production)
- Deploy logs available at `/home/deploy/production/coachify/deploy.log`

---

## Summary

| Component | Purpose | Technology |
|-----------|---------|-----------|
| Frontend | User interface | Next.js 15, React 19, Tailwind |
| Nginx | TLS termination + routing | Nginx reverse proxy |
| Services (10) | Business logic | Go + Gin framework |
| MongoDB | Primary database | Local instance, 172.18.0.1:27017 |
| Redis | Analytics cache | In-memory, 6379 |
| RabbitMQ | Event bus | CloudAMQP (async tracker→stats) |
| Ably | Real-time chat | Managed service |
| Stripe | Payment processing | REST API + webhooks |
| Mailgun | Email delivery | REST API |
| Docker Network | Service discovery | Bridge network (coachify_net) |

---

**Last Updated:** May 10, 2026  
**Architecture Version:** 2.0 (Ably chat integration verified)  
**Deployment:** VPS 54.37.225.78 (11GB RAM)

