# AGENTS.md

## Development Requirements

When developing the application, follow all of the following roles and standards:

- **Senior Product Manager**: Plan product capabilities, feature priorities, information architecture, and capability presentation. Prioritize core problems and avoid low-value features and unnecessary complexity.
- **Google Design Expert**: Use Material 3 Expressive (M3E) principles, components, and styles for page layouts, UI, and interactions. Keep the experience intuitive, concise, and consistent, and reuse existing design components whenever possible.
- **Senior Apple Developer**: Build according to Apple platform conventions. Keep the project architecture clear, module boundaries well-defined, and component responsibilities focused. Create appropriate abstractions for shared capabilities and extract common logic promptly.
- **Enterprise-Grade Open-Source Standards**: Code must be clear, reliable, maintainable, and testable. Avoid overengineering, ineffective abstractions, duplicate implementations, and unnecessary dependencies.
- **Implementation Principles**: Use the simplest implementation possible while preserving correctness, security, and maintainability. Do not add code with no practical value merely for the sake of “completeness.”
- **Documentation and Copy**: Communicate concisely, efficiently, and precisely. Avoid explanatory prose, repetition, and unnecessary background.
- **Git Commits**: Follow the Angular / Conventional Commits convention. Use explicit types such as `feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`, `test: ...`, and `chore: ...`. Commit messages must briefly describe the change and must not use vague or meaningless titles.

## Luti Constraints

### For Users

- Interactions must be simple, allowing users to get started and accomplish their goals as quickly as possible.
- Pages must be intuitive, with core capabilities presented directly whenever possible.
- Capability details, status, and advanced configuration belong on their respective detail pages and must not crowd the main page.
- Configuration must be simple. Do not require users to manually configure anything the application can automatically discover, infer, generate, or maintain.
- Minimize configuration options, interaction steps, repeated confirmations, and unnecessary pages.
- Defaults must cover most users. Expose advanced options only when they are genuinely needed.

### For the Application

- Keep the number of Public Tools as small as possible without reducing capability. Growth in internal Detectors, Adapters, Providers, or Parsers must not automatically result in new Public Tools.
- Prefer extending existing Tools, actions, and underlying capabilities. Add a Public Tool only when existing primitives cannot reliably express a new system capability, risk boundary, or structured real-time state.
- Design Tools around stable, sufficient, and orthogonal core primitives. Avoid overlapping functionality and protocol noise.
- Minimize the Host's Tool-selection cost, redundant queries, and the number of Agent Loops.
- When one call can return sufficiently structured results, do not split it into multiple meaningless calls.
- Do not merge distinct risk, permission, or side-effect boundaries merely to reduce the number of Tools or Loops.
- Reuse the existing architecture and shared capabilities for new functionality whenever possible. Avoid introducing unnecessary configuration, abstractions, pages, or code.
