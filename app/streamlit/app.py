"""
NorthPay CloudOps Agent — Streamlit chat UI
"""

import os
import uuid
import streamlit as st
from agent import build_agent

st.set_page_config(
    page_title="NorthPay CloudOps Agent",
    page_icon="🛡️",
    layout="wide",
)

st.title("🛡️ NorthPay CloudOps Agent")
st.caption("AI-powered cloud operations — security, cost, and compliance.")

# ── Session state ─────────────────────────────────────────────────────────────

if "messages" not in st.session_state:
    st.session_state.messages = []
if "session_id" not in st.session_state:
    st.session_state.session_id = str(uuid.uuid4())
if "agent" not in st.session_state:
    with st.spinner("Initialising agent..."):
        st.session_state.agent = build_agent()

# ── Sidebar ───────────────────────────────────────────────────────────────────

with st.sidebar:
    st.header("Quick prompts")
    quick_prompts = [
        "Which S3 buckets are public, and what does our runbook say to do?",
        "Why did our bill jump last week?",
        "Summarize our PCI-relevant findings for an auditor.",
        "Are there any IAM users without MFA?",
        "Show me our highest-severity Security Hub findings.",
    ]
    for prompt in quick_prompts:
        if st.button(prompt, use_container_width=True):
            st.session_state.pending_prompt = prompt

    st.divider()
    st.caption(f"Session: `{st.session_state.session_id[:8]}...`")
    if st.button("🗑️ Clear chat", use_container_width=True):
        st.session_state.messages = []
        st.session_state.session_id = str(uuid.uuid4())
        st.rerun()

# ── Chat history ──────────────────────────────────────────────────────────────

for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])

# ── Handle quick prompts ──────────────────────────────────────────────────────

if "pending_prompt" in st.session_state:
    user_input = st.session_state.pop("pending_prompt")
else:
    user_input = st.chat_input("Ask about security, cost, or compliance...")

# ── Process input ─────────────────────────────────────────────────────────────

if user_input:
    st.session_state.messages.append({"role": "user", "content": user_input})
    with st.chat_message("user"):
        st.markdown(user_input)

    with st.chat_message("assistant"):
        with st.spinner("Thinking..."):
            try:
                agent = st.session_state.agent
                response = agent(user_input)
                reply = str(response)
            except Exception as exc:
                reply = f"⚠️ Error: {exc}"

        st.markdown(reply)
        st.session_state.messages.append({"role": "assistant", "content": reply})
