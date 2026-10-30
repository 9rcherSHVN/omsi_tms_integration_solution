sequenceDiagram
    participant ERP as ERP Application
    participant EDB as ERP Database
    participant Relay as ERP Outbox Relay
    participant Receiver as Integration Receiver
    participant IDB as Integration Database
    participant Worker as Integration Worker

    ERP->>EDB: Begin transaction A
    ERP->>EDB: Save shipment and ShipmentReady outbox message
    ERP->>EDB: Commit transaction A
    Relay->>EDB: Claim committed pending delivery
    Relay->>Receiver: Send message with stable message ID
    Receiver->>IDB: Transaction B stores message and unique inbox receipt
    IDB-->>Receiver: Commit durable receipt
    Receiver-->>Relay: Acknowledge durable receipt
    Relay->>EDB: Mark delivery acknowledged
    Worker->>IDB: Claim pending inbox work
    Worker->>IDB: Begin transaction C
    Worker->>IDB: Lock receipt and check whether already applied
    Worker->>IDB: Validate identity and business version
    Worker->>IDB: Update projections and process state
    Worker->>IDB: Append transitions and RequestTender outbox message
    Worker->>IDB: Mark inbox receipt applied
    Worker->>IDB: Commit transaction C