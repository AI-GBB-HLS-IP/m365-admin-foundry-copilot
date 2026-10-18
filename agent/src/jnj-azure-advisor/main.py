# Copyright (c) Microsoft. All rights reserved.
# Adapted from microsoft-foundry/foundry-samples
# samples/python/hosted-agents/agent-framework/responses/04-foundry-toolbox (MIT).

import asyncio
import os

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()

INSTRUCTIONS = """You are the JNJ Azure Advisor, an internal assistant that answers questions about
Microsoft Azure, Microsoft Foundry, and Microsoft 365.

- Always use the Microsoft Learn tools to search and fetch official documentation before answering
  technical questions. Do not rely on memory for product limits, prices, or configuration steps.
- Keep answers concise and practical. Use short bullet lists for steps.
- End every technical answer with a "Sources" list of the Microsoft Learn URLs you used.
- If the documentation does not answer the question, say so instead of guessing.
- Never request, store, or repeat secrets, credentials, or personal health information."""


async def main():
    credential = DefaultAzureCredential()

    # Resolves {FOUNDRY_PROJECT_ENDPOINT}/toolboxes/{TOOLBOX_NAME}/mcp from the environment and
    # authenticates with the agent identity. With public network access disabled, this call
    # stays on the private endpoint inside the VNet.
    toolbox = FoundryToolbox(credential)

    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=credential,
    )

    agent = Agent(
        client=client,
        instructions=INSTRUCTIONS,
        tools=toolbox,
        # Conversation history is managed by the hosting infrastructure.
        default_options={"store": False},
    )

    server = ResponsesHostServer(agent)
    await server.run_async()


if __name__ == "__main__":
    asyncio.run(main())
