Hi everyone, good morning.

Today, I'd like to walk you through our ADR for **integrating Linux system logs into LaaS using Fluent-Bit**.

### 1. Background

Currently, the Linux team uses centralized Rsyslog servers to collect system logs from Linux servers.

However, Linux SREs don't have a dedicated centralized platform to efficiently search and troubleshoot these logs.

Our main goal is to provide centralized log visibility through LaaS, while supporting our regulatory and internal compliance requirements.

We also want to support the planned Splunk decommissioning.

### 2. Decision Drivers

Before introducing the solutions, I'd like to briefly highlight our seven key decision drivers.

**First, Business and Regulatory Alignment.**

We want to provide centralized Linux log visibility and meet our internal and regulatory logging requirements.

**Second, Minimal Infrastructure Changes.**

We want to reuse the existing infrastructure and minimize additional servers, firewall changes, and client-side configuration updates.

**Third, Availability and Resilience.**

We need to consider potential single points of failure and ensure the logging pipeline can recover from temporary service interruptions.

**Fourth, Resource Efficiency and Cost.**

We want to balance the benefits of high availability against additional infrastructure costs, network traffic, and resource consumption.

**Fifth, Scalability and Performance.**

The solution needs to support our current and future log volumes without significantly impacting the existing infrastructure.

**Sixth, Security and Multi-Tenancy.**

We need to make sure that Linux logs are securely forwarded to the correct Loki tenants based on their Legal Entities.

**And finally, Operational Supportability.**

We want the solution to be easy to deploy, monitor, maintain, and troubleshoot, with minimal dependencies on other teams.

With these drivers in mind, we evaluated two options together with the Linux team.

### 3. Option A – Recommended Solution

The first option is to deploy Fluent-Bit directly on the existing Rsyslog servers.

As you can see from the diagram, Rsyslog continues collecting Linux system logs and writing them to local files.

Fluent-Bit uses the Tail input to read these files, perform parsing and tenant mapping, and forward the logs to the corresponding Loki tenants.

The Linux team will provide a dedicated SystemID with permission to write to multiple Linux-related tenants.

The main advantage is that we can reuse the existing infrastructure without additional servers or client-side configuration changes.

The main concern is additional resource consumption, especially file descriptors, memory, and disk I/O, which we will monitor and validate.

### 4. Option B – Long-Term Alternative

The second option is to reuse the Fluent-Bit agents already deployed on each Linux server.

Each agent would collect local logs and forward them to a dedicated Fluent-Bit Collector Cluster, which would then send the logs to Loki.

The main advantage is better availability, because LaaS would no longer depend on the centralized Rsyslog servers.

However, this requires additional Collector servers, firewall changes, potentially F5 load balancing, and more configuration management.

It also introduces additional network traffic, since the existing Syslog forwarding would remain in place.

So, the key question is whether the improved availability justifies the additional infrastructure investment and operational complexity.

### 5. Decision Outcome

After evaluating both options against our decision drivers, **we recommend Option A for the initial implementation**.

Both options can meet our centralized logging and security requirements.

Option B offers better failure isolation and scalability potential.

However, Option A performs better in terms of infrastructure reuse, resource efficiency, cost, and operational supportability.

We understand that the centralized Rsyslog servers remain a dependency, but we consider this an acceptable trade-off based on our current requirements.

Option B will remain a potential long-term alternative if higher availability requirements arise.

That concludes our proposed architecture and the reasoning behind our decision.

**Thank you. I'm happy to take any questions or feedback.**

Q1: What happens if the Rsyslog server goes down?
This is one of the risks we discussed with the Linux team. If the Rsyslog server becomes unavailable, new logs may not reach LaaS until the service recovers. However, Option A allows Fluent-Bit to resume collecting logs that have already been written to local files. We have accepted the centralized Rsyslog dependency for the initial implementation.

Q2: Why don't we choose Option B if it provides better HA?
Option B does provide better failure isolation, but it also requires additional infrastructure, network configuration, and operational maintenance. Based on our current requirements, we believe Option A is more resource-efficient. We can revisit Option B if stronger availability requirements emerge.

Q3: How do we ensure logs are routed to the correct Loki tenant?
The Linux team will provide a dedicated SystemID authorized to write to multiple Linux-related tenants. Fluent-Bit will use source information, such as hostname, together with predefined tenant mapping rules to route logs to the appropriate tenant.
