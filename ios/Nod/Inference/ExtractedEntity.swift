// ExtractedEntity.swift
// The raw output shape of the entity-extraction LLM call.
//
// Two types because `@Generable` needs a top-level holder — Apple's
// FoundationModels framework doesn't directly support `[@Generable]`
// as a root type, so we wrap the list inside `ExtractedEntities`.
//
// These are the wire format between the LLM and our app. They are NOT
// the persisted type — conversion to `Entity` happens in EntityStore
// after dedup / alias-match / disambiguation logic. Keeping these
// decoupled means the persisted schema can evolve (adding fields,
// renaming) without having to rev the LLM-facing contract too.
//
// @Guide annotations are the instructions the model reads at generation
// time. Think of them as per-field prompts. Keep them specific, imperative,
// and consistent with the system prompt in prompts/entity_extraction.md.

import FoundationModels

@Generable
struct ExtractedEntities {
    @Guide(description: "The list of entities mentioned in the conversation chunk. Empty if nothing specific was mentioned.")
    var items: [ExtractedEntity]
}

@Generable
struct ExtractedEntity {
    @Guide(description: "One of: person, place, project, situation. Lowercase.")
    var type: String

    @Guide(description: "The name or reference as the user used it (e.g. 'M', 'Jennifer', 'the fintech interview'). Do not normalize — preserve user's spelling.")
    var name: String

    @Guide(description: "Relationship or kind (e.g. 'manager', 'partner', 'interview process', 'coffee shop'). Empty string if the user did not say.")
    var role: String

    @Guide(description: "A short factual sentence of context, max 15 words. Stay in the user's own words. No diagnosis or interpretation. Empty string if nothing to add.")
    var note: String
}
