# Script for populating the database. Idempotent-safe to run repeatedly.
#
#     mix run priv/repo/seeds.exs

NursePrep.Questions.seed_canonical_subjects()
