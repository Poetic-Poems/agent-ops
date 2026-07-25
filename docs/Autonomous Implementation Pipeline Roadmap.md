# Autonomous Implementation Pipeline Roadmap

## Vision

The *Autonomous Implementation Pipeline* will be a monetised product that can
easily be applied to a variety of target repository.

## Characteristics of the End-State Product

- The pipeline will be untehthered from Poetic-Poems, with Poetic-Poems using
  it as an external tool.
- Pipeline containers will be deployed via an orchestration tool (for example,
  Kubernetes).
- Autoscaling will be possible.
- Scale-to-zero will be possible.
- No manual per-container steps will be required.
- Updates to the pipeline itself will be no-intrusive (i.e., it won't disrupt
  in-progress work).
- It will be very customisable, including being able to choose which models are
  used for the Actor agents (Co-Ordinator, simple Implementator, complex
  Implementator, simple Reviewer, complex Reviewer, Enabler), and the cron
  schedules.
- A variety of hosting options will be supported.
- The pipeline code might or might not be open source; wantever works best for
  monetisation.
- The name might be changed to something more marketable.
