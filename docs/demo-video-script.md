# Demo video: Private Foundry agent → Microsoft 365 Copilot and Teams

Shot-by-shot recording guide and AI voiceover script for the JNJ POC showcase. The target length is about **6 minutes** at roughly 150 words per minute. Each scene has its own narration block so you can create one Clipchamp text-to-speech clip per scene and align it with that scene's recording.

## Before you record

### Environment checklist

| ✔ | Item | How |
|---|---|---|
| ☐ | Jumpbox running. You only need it if you rerun scripts. | `az vm start -g rg-jnj-foundry-m365-poc -n vm-jnjm365-jumpbox` |
| ☐ | Microsoft corporate VPN (`MSFT-AzVPN-Manual`) **disconnected** for the whole recording | Windows **Settings** > **Network & internet** > **VPN** |
| ☐ | Azure VPN Client profile `jnj-foundry-poc` imported and **disconnected** at the start | Azure VPN Client |
| ☐ | Agents warmed up so answers appear in seconds | Connect the VPN, send one prompt to **jnj-azure-advisor** in the Foundry playground about 5 minutes before recording, then disconnect |
| ☐ | **JNJ Azure Advisor (Demo)** shows as **Pending review** | M365 admin center > **Agents** > **All agents** > **Requests**. It was submitted by `publish-agent.ps1 -AgentName jnj-azure-advisor-demo -PublishScope Tenant`. |
| ☐ | **JNJ Azure Advisor** is available in Teams for `sg-jnj-azure-advisor-pilot` | Teams admin center > **Manage apps** > **JNJ Azure Advisor** > **Users and groups** |
| ☐ | A group chat for the @mention shot, such as "JNJ AI Pilot" with one other member | Teams |
| ☐ | VS Code open on this repository with `scripts/publish-agent.ps1` and `scripts/jumpbox/publish-agent.sh` in tabs | VS Code |

### Recording settings

- **Resolution:** 1920×1080 at 100% display scaling. Use browser zoom of 110–125% for readability.
- **Browser:** A clean Microsoft Edge profile signed in as `KaiC@M365CPI47937014.OnMicrosoft.com`. Hide the favorites bar and close unrelated tabs.
- **Distractions:** Turn on **Do not disturb**. Close Outlook and any notification sources.
- **Recorder:** Clipchamp **Record & create** > **Screen**, or Snipping Tool video mode (**Win+Shift+R**). Record **one file per scene**.
- **Pacing:** Pause about 1 second before and after each click. You can trim the pauses later.

### Tabs to pre-open

1. Foundry portal: https://ai.azure.com > project **m365agentslfzg** > **Agents**
2. Azure portal: Foundry resource `jnjm365fdylfzg` > **Networking**
3. M365 admin center: https://admin.cloud.microsoft/?#/agents/all/requested
4. Teams admin center: https://admin.teams.microsoft.com > **Teams apps** > **Manage apps**
5. Microsoft Teams, in the desktop app or https://teams.microsoft.com
6. Microsoft 365 Copilot: https://m365.cloud.microsoft/chat

---

## Scene 1: Private by default (VPN disconnected), about 35 seconds

**Logo cue:** Microsoft Foundry

**Record:**
1. Start on the Foundry portal **Agents** page for project **m365agentslfzg**.
2. Hold on the **Network access unavailable** banner and the **Error loading your agents: Public access is disabled** message for about 4 seconds.
3. Slowly highlight the banner text with the mouse.

**Caption:** "Public network access: Disabled"

**Narration:**
> This is a Microsoft Foundry project built for Johnson and Johnson. I'm opening it from the public internet, and Foundry won't show me the agents. The account has public network access turned off, so its agent APIs only answer requests that come from inside the company's private network. Even with the right permissions, you can't reach this agent from outside.

---

## Scene 2: Inside the VNet, about 70 seconds

**Logo cues:** Azure VPN, Azure Virtual Network, Microsoft Foundry

**Record:**
1. Open the **Azure VPN Client**, select **jnj-foundry-poc**, select **Connect**, and complete sign-in as Kai. Show **Connected**.
2. Switch to the Azure portal tab with **jnjm365fdylfzg** > **Networking**. Show **Public network access: Disabled**, the **Private endpoint connections** entry, and the **virtual network injection** of `agent-subnet`.
3. Switch to the Foundry portal and refresh. The agents list now loads.
4. Open **jnj-azure-advisor**. Briefly show **Details**: hosted agent, version, and the `learn-tools` toolbox.
5. Open the **Playground** and send: **How do I publish a Foundry agent to M365 Copilot within a private network?**
6. Wait for the full answer. Scroll slowly through it and the **Sources** list.

**Caption:** "Connected through a point-to-site VPN with Microsoft Entra ID sign-in"

**Narration:**
> Now I connect to the private network with Azure VPN, signing in with Microsoft Entra ID. In the Azure portal you can see the setup: public access is disabled, the project is reached through private endpoints, and the agent's compute runs inside the company's own virtual network. Its threads, files, and search indexes live in Cosmos DB, Storage, and AI Search, all behind private endpoints.
>
> Back in Foundry, the agents now load. This is JNJ Azure Advisor, a hosted agent built with Microsoft Agent Framework. It answers Azure, Foundry, and Microsoft 365 questions using the Microsoft Learn MCP server, through a Foundry toolbox. Outbound calls leave through Azure Firewall, which only allows the domains we approve. Let's ask it how to publish a Foundry agent to Microsoft 365 Copilot from a private network.
>
> The agent searches Microsoft Learn through MCP, then returns a grounded, step-by-step answer with sources.

---

## Scene 3: Publishing privately (VS Code), about 75 seconds

**Logo cues:** Visual Studio Code, Azure Bot Service

**Record:**
1. In VS Code, show the repository tree: `infra/`, `agent/`, `scripts/`, `docs/`.
2. Open `scripts/publish-agent.ps1`. Scroll slowly past the comments for steps 1–4.
3. Open `scripts/jumpbox/publish-agent.sh`. Highlight the `enable_m365_public_endpoint: true` patch and the `microsoft365/publish` call.
4. Optional: open `infra/bot-service.bicep` and highlight `publicNetworkAccess: 'Disabled'` and the endpoint containing `?api-version=v1`.
5. Show the Tenant vs. Shared comparison card. Make it in Clipchamp, or show the table in `docs/governance.md`.

**Caption:** "Agent management APIs stay private. Only the Activity Protocol route is opened, and only to Microsoft 365 traffic."

**Narration:**
> Now we want a wider audience, so we'll publish this agent to Microsoft 365 Copilot and Teams without opening the private network. This script does it in four steps. Because the project rejects public callers, the steps that talk to Foundry run on a machine inside the network, triggered through Azure Run Command.
>
> First, it reads the agent's Microsoft Entra identity. Second, it creates an Azure Bot Service resource, with public network access disabled, that relays Teams and Copilot traffic. Third, it turns on one narrow exception: the agent's Activity Protocol endpoint, the route Microsoft 365 uses to deliver messages. Foundry only accepts calls on that route from Microsoft 365 and Bot Service addresses, and each request still has to pass token and tenant checks. Every other Foundry API stays private. Fourth, it calls the Microsoft 365 publish API.
>
> There are two publishing scopes. Shared publishes to you only, with no admin approval, and anyone you share it with also needs Azure permissions on the Foundry project. Tenant submits the agent for Microsoft 365 admin approval, and the admin decides which users or groups get it.

**Comparison card (on screen):**

| Shared | Tenant |
|---|---|
| Developer publishes, no approval | Microsoft 365 admin approval required |
| Visible to the publisher, shared by link | Admin assigns users, groups, or everyone |
| Callers need Foundry RBAC on the project (`BotServiceRbac`) | Any tenant user who has the app (`BotServiceTenant`) |
| Dev, test, and small pilots | Organization-wide rollout |

---

## Scene 4: Admin approval (Microsoft 365 admin center), about 70 seconds

**Logo cue:** Microsoft 365 admin center

**Record:**
1. Go to **Agents** > **All agents** > **Requests**. Show **JNJ Azure Advisor (Demo)** as **Pending review**.
2. Open it. Click through the details: description, publisher, host products (**Copilot** and **Teams**), and data and tools.
3. Select **Publish to store**.
4. On **Select users or groups who can install the agent**, show the options. Hover over **All users**, then choose **Specific users or groups**, search for and select `sg-jnj-azure-advisor-pilot`, and optionally add a single user to show both choices.
5. Optional: add the same group under **pre-installed**.
6. Select **Next** for the policy template. Keep the default template, review the permissions, and select **Publish**.
7. Open **Registry**, find the agent, and hover over **Block** without clicking it. This shows the kill switch.

**Caption:** "Access = membership of an Entra security group"

**Narration:**
> Shared scope is great for testing and proofs of concept, but here we'll walk through the organization-wide path. Because we published with Tenant scope, the agent arrives in the Microsoft 365 admin center under Agents, in the Requests tab, waiting for review.
>
> The admin can review the agent's description, publisher, where it runs, and what data and tools it uses before deciding. Choosing Publish to store opens the rollout wizard. Here the admin controls who gets the agent: everyone in the organization, specific people, or Microsoft Entra security groups. We'll pick our pilot group, so access, and the number of people who have it, comes down to that group's membership. The admin can also pre-install it, apply a policy template, and review permissions before publishing.
>
> After it's published, the agent shows up in the Agent Registry. From there, admins can change the audience, install it for more people, or block it in one click.

---

## Scene 5: Using it in Teams, about 75 seconds

**Logo cues:** Teams admin center, Microsoft Teams

**Record:**
1. In the **Teams admin center**, go to **Teams apps** > **Manage apps**, search for **JNJ Azure Advisor**, and open **Users and groups** > **Edit availability**. Show `sg-jnj-azure-advisor-pilot` selected.
2. Switch to **Teams**. Open **Apps** > **Built for your org** > **JNJ Azure Advisor** > **Open**.
3. In the 1:1 chat, send: **How do I publish a Foundry agent to M365 Copilot within a private network?** Wait for the reply.
4. Open the group chat "JNJ AI Pilot". If the agent isn't in the chat yet, select **+** next to the chat name, choose **Apps**, and add **JNJ Azure Advisor**. Then type **@JNJ Azure Advisor** followed by the same question and send it.
5. Hold on the reply in the group chat.

**Caption:** "Same private agent, now inside Teams"

**Narration:**
> In Teams, availability is controlled by the Teams admin center. Under Manage apps, the Teams admin limits the agent to the same pilot group, so Copilot and Teams share the same audience.
>
> Users in that group find the agent under Built for your org and open it. In a one-to-one chat, I'll ask the same question. The message goes from Teams through Bot Service to the agent's restricted Activity endpoint. The agent runs inside the private network, calls Microsoft Learn through MCP, and sends the answer back to Teams.
>
> The agent works in group chats and channels too. Add it to a chat, at-mention JNJ Azure Advisor, and everyone in the conversation sees a grounded answer.

---

## Scene 6: Microsoft 365 Copilot agent store, about 30 seconds

**Logo cue:** Microsoft 365 Copilot

**Record:**
1. Open https://m365.cloud.microsoft/chat. Select **All agents** or **Get agents** to open the agent store.
2. Open **Built by your org** and select **JNJ Azure Advisor**.
3. Select **Add**. Show the agent pinned or listed in the left rail.
4. **Don't send a message.** Stop recording on the agent's start screen.

**Caption:** "Approved once, available in Microsoft 365 Copilot and Teams"

**Narration:**
> The same approval also publishes the agent to Microsoft 365 Copilot. In the agent store under Built by your org, users in the pilot group find JNJ Azure Advisor and add it with one click, right next to their other Copilot agents.

---

## Scene 7: Close, about 25 seconds

**Record:** A title card. Build it in Clipchamp with the logos below on a dark background, and the repository URL.

**On screen:**
- **Private Microsoft Foundry agents in Microsoft 365 Copilot and Teams**
- Standard Agent Setup: private endpoints, VNet injection, and BYO Cosmos DB, AI Search, and Storage
- Governed egress with Azure Firewall · MCP tool through Foundry toolbox
- Microsoft 365 admin approval · Entra group–scoped access
- `github.com/AI-GBB-HLS-IP/m365-admin-foundry-copilot`

**Narration:**
> To recap: the agent, its data, and its tools stay in a private network, with outbound calls limited by the firewall. A single, filtered Activity route connects it to Microsoft 365. And IT controls who can use it, with admin approval and group-based access in Copilot and Teams. Everything you saw, including infrastructure, scripts, and governance guidance, is in the repository.

---

## Branding and logos

| Logo | Scenes | Where to get it |
|---|---|---|
| Microsoft Foundry | 1, 2, 7 | Azure architecture icons, under **AI + machine learning**: https://learn.microsoft.com/azure/architecture/icons/ |
| Azure Virtual Network, Azure VPN Gateway, Azure Firewall | 2, 7 | Azure architecture icons, under **Networking** |
| Azure Bot Service | 3 | Azure architecture icons, under **AI + machine learning** |
| Visual Studio Code | 3 | https://code.visualstudio.com/brand |
| Microsoft 365 admin center, Microsoft Teams, Microsoft 365 Copilot | 4–7 | Microsoft 365 product icons from Microsoft Brand Central (internal), or the Microsoft 365 icon set |
| Microsoft logo | 7 | Microsoft Brand Central (internal) |

Follow Microsoft brand guidelines: don't recolor, stretch, or crop logos, and keep clear space around them. Place a small product logo in the top-right corner for 3–4 seconds when each scene starts, or show it next to the scene's caption.

## Clipchamp assembly

1. **Project:** Create a new video with a 16:9 (1920×1080) aspect ratio and import the seven scene recordings.
2. **Voiceover:** Select **Record & create** > **Text to speech**. Create **one clip per scene**: paste that scene's narration, choose one voice for all clips (a natural neural voice, such as one of the newer US English voices), and keep the speed at 1.0×. Name the clips `VO-1` through `VO-7`.
3. **Timeline:** Put the video clips on track 1, voiceover on track 2, and logos and captions on track 3.
4. **Sync:** For each scene, trim or speed up the waiting periods so the video length matches the voiceover. Use **Speed** 1.5–2× while the agent is thinking, with a small "⏩ sped up" caption. Each scene should end about 0.5 seconds after its narration.
5. **Captions:** Use **Captions** > **Turn on auto captions** for accessibility, and review the spelling of *Foundry*, *MCP*, *Entra*, and *JNJ*.
6. **Transitions:** Use a simple **Cross fade** between scenes (0.5 seconds) and no other effects.
7. **Music (optional):** Add a soft Clipchamp stock track at -25 to -30 dB under the voiceover.
8. **Export:** 1080p. Review it once at full screen to check for personal or tenant information you want to blur, such as email addresses or other tenants' agents in lists. Use **Blur** effects where needed.

## After recording

- **Demo agent:** It can stay as a second example. To remove it from Microsoft 365, block or delete **JNJ Azure Advisor (Demo)** in the Agent Registry, then delete bot `bot-jnj-azure-advisor-demo-jnjm365fdylfzg` and agent `jnj-azure-advisor-demo`.
- **Repeat take of scene 4:** An approved app won't return to **Pending review**. Republishing with a new `-AppVersion` only produces **Pending update**, which uses the **Update in store** flow instead of the audience wizard. For a fresh **Pending review**, create a new demo agent with a different name and publish it with `-PublishScope Tenant`. The steps match how `jnj-azure-advisor-demo` was created; see the commit history.
