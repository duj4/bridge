Hi everyone, good morning.

Today, I'd like to walk you through our ADR for **integrating Linux system logs into LaaS using Fluent-Bit**.

### 1. Background

Currently, the Linux team uses centralized Rsyslog servers to collect system logs from Linux servers.

However, the Linux SRE team doesn't have a dedicated centralized platform to search and troubleshoot these logs efficiently.

Our main goal is to provide **centralized log visibility through LaaS**, so that Linux SREs can easily search, monitor, and investigate system logs using Grafana.

At the same time, this integration will help us align with our regulatory and internal compliance requirements for centralized log management.

Another consideration is the planned Splunk decommissioning, so we also want to ensure that Linux system logs remain accessible through LaaS in the future.

### 2. Decision Drivers

Before going into the technical options, I'd like to briefly highlight the key decision drivers.

**First, centralized visibility and compliance.**

We want to provide a reliable, centralized logging platform for Linux SREs, while supporting our security and regulatory requirements.

**Second, minimal infrastructure changes.**

We want to reuse our existing infrastructure as much as possible, and avoid unnecessary changes to Linux servers, firewall rules, or network configurations.

**Third, availability and reliability.**

We need to consider potential single points of failure and ensure the logging pipeline can recover from temporary service interruptions.

**Fourth, resource efficiency and operational complexity.**

We want to balance the benefits of high availability against additional infrastructure costs, network traffic, and maintenance effort.

**And finally, multi-tenancy and security.**

Since LaaS is a multi-tenant platform, we need to make sure logs are securely forwarded to the correct Loki tenants based on their Legal Entities.

With these drivers in mind, we evaluated two options together with the Linux team.

### 3. Option A – Recommended Solution

The first option is to **deploy Fluent-Bit directly on the existing Rsyslog servers**.

As you can see from the diagram, Rsyslog continues collecting Linux system logs and writing them to local files.

Fluent-Bit then uses the Tail input to read these files, perform parsing and tenant mapping, and forward the logs to the corresponding Loki tenants.

The Linux team will provide a dedicated SystemID with permission to write to multiple Linux-related tenants.

The main advantage of this option is that we can **reuse the existing infrastructure**.

We don't need additional servers, client-side configuration changes, or new inbound firewall rules.

The main concern is the additional resource consumption on the Rsyslog servers, especially file descriptors, memory, and disk I/O.

We will continue to monitor and validate these during implementation.

### 4. Option B – Long-Term Alternative

The second option is to **reuse the Fluent-Bit agents already deployed on each Linux server**.

Each agent would collect local system logs and forward them to a dedicated Fluent-Bit Collector Cluster, which would then send the logs to Loki.

The main advantage here is **better availability**, because the LaaS logging pipeline would no longer depend on the centralized Rsyslog servers.

However, this comes with additional costs and complexity.

We would need dedicated Collector servers, additional firewall rules, potentially F5 load balancing, and configuration management across the Linux servers.

It would also generate additional network traffic, since the existing Syslog forwarding would remain in place.

So, during our discussion with the Linux team, we considered whether the additional HA capability would really justify these extra resources and operational overhead.

### 5. Decision Outcome

After evaluating both options against our decision drivers, **we recommend Option A for the initial implementation**.

We believe it provides the best balance between **infrastructure reuse, resource efficiency, reliability, and operational simplicity**.

We understand that the centralized Rsyslog servers remain a dependency, but we consider this an acceptable trade-off based on our current requirements.

Option B will remain a potential long-term alternative if higher availability requirements arise in the future.

So, that's our proposed architecture and the reasoning behind our decision.

**Thank you. I'm happy to take any questions or feedback.**


Q1: What happens if the Rsyslog server goes down?
This is one of the risks we discussed with the Linux team. If the Rsyslog server becomes unavailable, new logs may not reach LaaS until the service recovers. However, Option A allows Fluent-Bit to resume collecting logs that have already been written to local files. We have accepted the centralized Rsyslog dependency for the initial implementation.

Q2: Why don't we choose Option B if it provides better HA?
Option B does provide better failure isolation, but it also requires additional infrastructure, network configuration, and operational maintenance. Based on our current requirements, we believe Option A is more resource-efficient. We can revisit Option B if stronger availability requirements emerge.

Q3: How do we ensure logs are routed to the correct Loki tenant?
The Linux team will provide a dedicated SystemID authorized to write to multiple Linux-related tenants. Fluent-Bit will use source information, such as hostname, together with predefined tenant mapping rules to route logs to the appropriate tenant.
