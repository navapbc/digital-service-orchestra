# Software Design Patterns Catalog for LLM Agents

## Agent Instruction: Selecting an Appropriate Design Pattern
**Purpose:** This catalog provides a shared vocabulary and decision-making framework to facilitate communication about software architecture and improve software design quality.

**Selection Protocol:** When tasked with designing a system, component, or refactoring existing code, execute the following steps:
1.  **Analyze the Problem:** Identify the core friction point. Is it related to object creation (Creational), object assembly/structure (Structural), or communication between objects (Behavioral)?
2.  **Evaluate Trade-offs:** Avoid premature optimization. Only select a pattern if the system's flexibility requirements outweigh the added complexity of the pattern.
3.  **Consult the Catalog:** Match the problem characteristics against the "When to Use" conditions below.
4.  **Verify Contraindications:** Strictly check the "When NOT to Use" conditions. If your scenario matches, discard the pattern and seek a simpler alternative or a different pattern.
5.  **Implement:** Use the standardized name in explanations to users to maintain a shared semantic understanding.

---

## 1. Creational Patterns
Creational patterns abstract the instantiation process, making a system independent of how its objects are created, composed, and represented.

### 1.1. Factory Method
* **Definition:** Provides an interface for creating objects in a superclass, but allows subclasses to alter the type of objects that will be created.
* **When to Use:** * When you don't know beforehand the exact types and dependencies of the objects your code should work with.
    * When you want to provide users of your library/framework with a way to extend its internal components.
* **When NOT to Use:** * When the hierarchy of creator classes is unnecessary (e.g., only one type of product exists). 
    * When a simple static creation method or simple factory suffices.
* **Reference:** [Factory Method](https://refactoring.guru/design-patterns/factory-method)

### 1.2. Abstract Factory
* **Definition:** Lets you produce families of related objects without specifying their concrete classes.
* **When to Use:** * When your code needs to work with various families of related products, but you don't want it to depend on the concrete classes of those products.
    * When you need to enforce consistency among products created together (e.g., UI themes).
* **When NOT to Use:** * When adding new kinds of products (not families) is a frequent requirement, as it requires changing the abstract interface and all implementations.
* **Reference:** [Abstract Factory](https://refactoring.guru/design-patterns/abstract-factory)

### 1.3. Builder
* **Definition:** Lets you construct complex objects step by step. Allows producing different types and representations of an object using the same construction code.
* **When to Use:** * To avoid a "Telescoping Constructor" anti-pattern (constructors with a massive number of optional parameters).
    * When you want to create different representations of some product (e.g., building a Stone House vs. Wood House).
* **When NOT to Use:** * For simple objects with few properties.
    * When the properties are required and never change, a standard constructor is safer and simpler.
* **Reference:** [Builder](https://refactoring.guru/design-patterns/builder)

### 1.4. Prototype
* **Definition:** Lets you copy existing objects without making your code dependent on their classes.
* **When to Use:** * When instantiation is expensive (e.g., requires database calls or complex calculations) and you need multiple similar instances.
    * When your code shouldn't depend on the concrete classes of objects that you need to copy.
* **When NOT to Use:** * When objects have complex object graphs with circular references (deep copying becomes error-prone and highly complex).
* **Reference:** [Prototype](https://refactoring.guru/design-patterns/prototype)

### 1.5. Singleton
* **Definition:** Ensures that a class has only one instance, while providing a global access point to this instance.
* **When to Use:** * When a class in your program should have just a single instance available to all clients (e.g., a shared database connection pool or hardware manager).
* **When NOT to Use:** * As a replacement for global variables to pass data around.
    * When unit testing is heavily hindered by the hidden dependencies introduced by the Singleton.
    * In multi-threaded environments where strict synchronization controls aren't feasible.
* **Reference:** [Singleton](https://refactoring.guru/design-patterns/singleton)

---

## 2. Structural Patterns
Structural patterns explain how to assemble objects and classes into larger structures, while keeping these structures flexible and efficient.

### 2.1. Adapter
* **Definition:** Allows objects with incompatible interfaces to collaborate.
* **When to Use:** * When you want to use an existing class, but its interface isn't compatible with the rest of your code.
    * To create a reusable class that cooperates with unrelated or unforeseen classes.
* **When NOT to Use:** * When it is possible and easier to simply alter the source code of the incompatible class.
* **Reference:** [Adapter](https://refactoring.guru/design-patterns/adapter)

### 2.2. Bridge
* **Definition:** Lets you split a large class or a set of closely related classes into two separate hierarchies (abstraction and implementation) which can be developed independently.
* **When to Use:** * When you want to divide and organize a monolithic class that has several variants of some functionality (e.g., if the class can work with various database servers).
    * When you need to extend a class in several orthogonal (independent) dimensions.
* **When NOT to Use:** * When you only have a single dimension of variation. It introduces unnecessary indirection.
* **Reference:** [Bridge](https://refactoring.guru/design-patterns/bridge)

### 2.3. Composite
* **Definition:** Lets you compose objects into tree structures and then work with these structures as if they were individual objects.
* **When to Use:** * When you need to implement a tree-like object structure (e.g., a file system or UI component hierarchy).
    * When you want client code to treat both simple and complex elements uniformly.
* **When NOT to Use:** * When objects don't logically form a part-whole hierarchy.
    * When you need to restrict the types of components that a composite can contain (dynamic typing makes this difficult).
* **Reference:** [Composite](https://refactoring.guru/design-patterns/composite)

### 2.4. Decorator
* **Definition:** Lets you attach new behaviors to objects by placing these objects inside special wrapper objects that contain the behaviors.
* **When to Use:** * When you need to assign extra behaviors to objects at runtime without breaking the code that uses these objects.
    * When it's impossible or awkward to extend an object's behavior using inheritance.
* **When NOT to Use:** * When the system heavily relies on object identity (Decorators wrap objects, making `object == decoratedObject` evaluate to false).
    * When order of decorators must be strictly controlled, as it can lead to fragile configurations.
* **Reference:** [Decorator](https://refactoring.guru/design-patterns/decorator)

### 2.5. Facade
* **Definition:** Provides a simplified interface to a library, a framework, or any other complex set of classes.
* **When to Use:** * When you need a limited but straightforward interface to a complex subsystem.
    * When you want to structure a subsystem into layers.
* **When NOT to Use:** * When the client needs absolute control over the intricacies of the subsystem.
    * When the facade risks becoming a "God Object" coupled to all classes of an app.
* **Reference:** [Facade](https://refactoring.guru/design-patterns/facade)

### 2.6. Flyweight
* **Definition:** Lets you fit more objects into the available amount of RAM by sharing common parts of state between multiple objects instead of keeping all of the data in each object.
* **When to Use:** * Strictly for performance/memory optimization when a program must support a massive number of objects which barely fit into available RAM.
* **When NOT to Use:** * When memory isn't an issue. The pattern heavily complicates code and costs CPU time to look up shared context.
* **Reference:** [Flyweight](https://refactoring.guru/design-patterns/flyweight)

### 2.7. Proxy
* **Definition:** Lets you provide a substitute or placeholder for another object. A proxy controls access to the original object, allowing you to perform something either before or after the request gets through to the original object.
* **When to Use:** * Lazy initialization (virtual proxy).
    * Access control (protection proxy).
    * Local execution of a remote service (remote proxy).
    * Logging or caching requests.
* **When NOT to Use:** * When direct access is sufficient and the overhead of an extra layer affects performance unnecessarily.
* **Reference:** [Proxy](https://refactoring.guru/design-patterns/proxy)

---

## 3. Behavioral Patterns
Behavioral patterns take care of effective communication and the assignment of responsibilities between objects.

### 3.1. Chain of Responsibility
* **Definition:** Lets you pass requests along a chain of handlers. Upon receiving a request, each handler decides either to process it or to pass it to the next handler in the chain.
* **When to Use:** * When your program is expected to process different kinds of requests in various ways, but the exact types of requests and their sequences are unknown beforehand.
    * When it's essential to execute several handlers in a specific order (e.g., Middleware).
* **When NOT to Use:** * When there's a risk of the request being dropped if no handler catches it, and the system requires a guaranteed response.
    * When debugging complexity is a primary concern (tracing requests through long chains is difficult).
* **Reference:** [Chain of Responsibility](https://refactoring.guru/design-patterns/chain-of-responsibility)

### 3.2. Command
* **Definition:** Turns a request into a stand-alone object that contains all information about the request. This transformation lets you pass requests as a method arguments, delay or queue a request's execution, and support undoable operations.
* **When to Use:** * When you want to parameterize objects with operations.
    * When you want to queue operations, schedule their execution, or execute them remotely.
    * When you need to implement reversible operations (Undo/Redo).
* **When NOT to Use:** * For simple, direct method calls where queuing or undo functionalities will never be needed (results in over-engineering and class explosion).
* **Reference:** [Command](https://refactoring.guru/design-patterns/command)

### 3.3. Iterator
* **Definition:** Lets you traverse elements of a collection without exposing its underlying representation (list, stack, tree, etc.).
* **When to Use:** * When your collection has a complex data structure under the hood, but you want to hide its complexity from clients.
    * To reduce duplication of traversal code across the app.
* **When NOT to Use:** * If your application only works with simple collections where standard loops are completely sufficient.
* **Reference:** [Iterator](https://refactoring.guru/design-patterns/iterator)

### 3.4. Mediator
* **Definition:** Lets you reduce chaotic dependencies between objects. The pattern restricts direct communications between the objects and forces them to collaborate only via a mediator object.
* **When to Use:** * When it's hard to change some of the classes because they are tightly coupled to a bunch of other classes.
    * When you want to reuse a component but can't because it's too dependent on other components.
* **When NOT to Use:** * When the Mediator risks becoming a "God Object" that controls too much logic, centralizing complexity rather than reducing it.
* **Reference:** [Mediator](https://refactoring.guru/design-patterns/mediator)

### 3.5. Memento
* **Definition:** Lets you save and restore the previous state of an object without revealing the details of its implementation.
* **When to Use:** * When you want to produce snapshots of the object's state to be able to restore a previous state of the object.
    * When direct access to the object's fields/getters/setters violates its encapsulation.
* **When NOT to Use:** * When saving states is highly memory-intensive (e.g., saving massive objects repeatedly).
    * When languages already support reliable serialization/cloning mechanics natively.
* **Reference:** [Memento](https://refactoring.guru/design-patterns/memento)

### 3.6. Observer
* **Definition:** Lets you define a subscription mechanism to notify multiple objects about any events that happen to the object they're observing.
* **When to Use:** * When changes to the state of one object may require changing other objects, and the actual set of objects is unknown beforehand or changes dynamically.
    * Event handling systems and pub/sub architectures.
* **When NOT to Use:** * When order of notifications matters.
    * When there is a risk of memory leaks ("Lapsed Listener Problem") because observers are not properly unregistered.
* **Reference:** [Observer](https://refactoring.guru/design-patterns/observer)

### 3.7. State
* **Definition:** Lets an object alter its behavior when its internal state changes. It appears as if the object changed its class.
* **When to Use:** * When you have an object that behaves differently depending on its current state, the number of states is enormous, and the state-specific code changes frequently.
    * When you have a class polluted with massive conditionals (`switch` or `if`) that alter how the class behaves according to the current values of its fields.
* **When NOT to Use:** * When a state machine has only a few states or rarely changes.
* **Reference:** [State](https://refactoring.guru/design-patterns/state)

### 3.8. Strategy
* **Definition:** Lets you define a family of algorithms, put each of them into a separate class, and make their objects interchangeable.
* **When to Use:** * When you want to use different variants of an algorithm within an object and be able to switch from one algorithm to another during runtime.
    * When you have a lot of similar classes that only differ in the way they execute some behavior.
* **When NOT to Use:** * When algorithms rarely change. It adds unnecessary classes and interfaces.
    * When clients are entirely unaware of the differences between strategies, forcing them to select one creates bad UX/DX.
* **Reference:** [Strategy](https://refactoring.guru/design-patterns/strategy)

### 3.9. Template Method
* **Definition:** Defines the skeleton of an algorithm in the superclass but lets subclasses override specific steps of the algorithm without changing its structure.
* **When to Use:** * When you want to let clients extend only particular steps of an algorithm, but not the whole algorithm or its structure.
    * When you have several classes that contain almost identical algorithms with some minor differences.
* **When NOT to Use:** * When you need high flexibility. Template Method is based on inheritance (rigid) rather than composition.
    * When the algorithm has too many steps, making the base class hard to maintain.
* **Reference:** [Template Method](https://refactoring.guru/design-patterns/template-method)

### 3.10. Visitor
* **Definition:** Lets you separate algorithms from the objects on which they operate.
* **When to Use:** * When you need to perform an operation on all elements of a complex object structure (for example, an object tree).
    * When you want to clean up the business logic of auxiliary behaviors to focus strictly on core tasks.
* **When NOT to Use:** * When the class hierarchy of the elements you are visiting changes frequently. Every time a new class is added, all visitors must be updated.
* **Reference:** [Visitor](https://refactoring.guru/design-patterns/visitor)
