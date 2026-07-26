# MTP: A Meaning-Typed Language Abstraction for AI-Integrated Programming

arXiv:2405.08965 - Mars, Kang, Dantanarayana, Irugalbandara, Sivasothynathan, Tang (University of Michigan / Jaseci Labs)

The published version of this work appears as: "MTP: A Meaning-Typed Language Abstraction for AI-Integrated Programming" (arXiv:2405.08965).

## Published Abstract

Software development is shifting from traditional programming to AI-integrated applications that leverage generative AI and large language models (LLMs) during runtime. However, integrating LLMs remains complex, requiring developers to manually craft prompts and process outputs. Existing tools attempt to assist with prompt engineering, but often introduce additional complexity. This paper presents Meaning-Typed Programming (MTP), a novel paradigm that abstracts LLM integration through intuitive language-level constructs. By leveraging the inherent semantic richness of code, MTP automates prompt generation and response handling without additional developer effort. We introduce the (1) by operator for seamless LLM invocation, (2) MT-IR, a meaning-based intermediate representation for semantic extraction, and (3) MT-Runtime, an automated system for managing LLM interactions. We implement MTP in Jac, a programming language that supersets Python, and find that MTP significantly reduces coding complexity while maintaining accuracy and efficiency. MTP significantly reduces development complexity, lines of code modifications needed, and costs while improving run-time performance and maintaining or exceeding the accuracy of existing approaches. Our user study shows that developers using MTP completed tasks 3.2x faster with 45% fewer lines of code compared to existing frameworks. Moreover, MTP demonstrates resilience even when up to 50% of naming conventions are degraded, demonstrating robustness to suboptimal code. MTP is developed as part of the Jaseci open-source project, and is available under the module byLLM.


---

## Full preprint text

[2405.08965] LLMs are Meaning-Typed Code Constructs

-

-
-
-

# LLMs are Meaning-Typed Code Constructs

Jason Mars

University of Michigan
Jaseci Labs
profmars@umich.edu

  
Yiping Kang

University of Michigan
Jaseci Labs
ypkang@umich.edu

  
Jayanaka Dantanarayana

University of Michigan
Jaseci Labs
jayanaka.dantanarayana@jaseci.org

  
Chandra Irugalbandara

Jaseci Labs
chandra.irugalbandara@jaseci.org

  
Kugesan Sivasothynathan

University Of Moratuwa
Jaseci Labs
kugesan.sivasothynathan@jaseci.org

  
Lingjia Tang

University of Michigan
Jaseci Labs
lingjia@umich.edu

###### Abstract

Programming with Generative AI (GenAI) models is a type of Neurosymbolic programming and has seen tremendous adoption across many domains.
However, leveraging GenAI models in code today can be complex, counter-intuitive and often require specialized frameworks, leading to increased complexity.
This is because it is currently unclear as to the right abstractions through which we should marry GenAI models with the nature of traditional programming code constructs.

In this paper, we introduce a set of novel abstractions to help bridge the gap between Neuro- and symbolic programming.
We introduce , a new specialized type that represents the underlying semantic value of traditional types (e.g., string).
We make the case that GenAI models, LLMs in particular, should be reasoned as a -type wrapped code construct at the language level.
We formulate the problem of translation between meaning and traditional types and propose Automatic Meaning-Type Transformation (A-MTT), a runtime feature that abstracts this translation away from the developers by automatically converting between and types at the interface of LLM invocation.
Leveraging this new set of code constructs and OTT, we demonstrate example implementation of neurosymbolic programs that seamlessly utilizes LLMs to solve problems in place of potentially complex traditional programming logic.

###### Index Terms:

programming language, neurosymbolic, large language models

## I Introduction

Generative AI models, in particular Large Language Models (LLM), have seen tremendous adoption across many industries and are revolutionizing how developers program. Enterprises and startups are gearing up to integrate LLMs into their workflows. This raises the question “What will the future of programming look like?”. Symbolic programming has been the main programming paradigm, where symbolic code are used to express logic to complete a task or solve a problem.
On the other hand, with the fast adoption of LLMs, a new programming paradigm, Neurosymbolic programming  [ 1 ] , has quickly gained interests in academia and industry.
In Neurosymbolic programs, Neural Networks and traditional symbolic code are combined to create intelligent algorithm and applications.

Figure 1: Comparison of LLM as Meaning Typed Code construct abstraction (Right) with the present-day LLM abstraction (Middle) and Symbolic Programming Abstraction (Left) of a programming function.

LLMs operates on text as input and generates text as output.
Constructing the input text, also known as prompt, is currently the main method of programming with LLMs and is commonly referred to as prompt engineering.
Programming with LLMs today rely heavily on prompt engineering and this can introduce significant complexity.
Generating the right prompt from existing code constructs and elements in your program can be complex, tedious and reduce code readability and maintainability.
There have been several efforts in open-source and research community to assist with prompt engineering, such as LangChain, Guidance, Language Model Programming Language (LMQL)  [ 2 ] and SGLang  [ 3 ] .
These libraries aim to facilitate the construction of prompt and help with programming with LLMs.
However, these approaches mostly still require the developer to decide the type of prompt to use and what information should be part of the prompt.
In addition, there also exists non-trivial degree of challenges in parsing the LLM outputs and converting it to operatable code constructs.
Overall, it remains unclear what is the right methodology for programming with LLMs in neurosymbolic programming.

In this work, we postulate that the fundamental reason for the complexity of programming with LLMs is the lack of abstraction for interfacing with LLMs.
In conventional symbolic programs, code are used to describe operations that are conducted on variables or typed-values (Figure  1 left).
LLMs do not directly operate on variables.
So variables are first converted to a prompt (a string), then after the LLM inference, its output (also a string) are parsed are then converted to variables (Figure  1 middle).
This process represents how the existing frameworks approach programming with LLMs.
While this enables integrating LLMs, additional logic and complexity are introduced with the generation of the input prompt and parsing of the output response.
We think that this complexity exists because there exist a fundamental disagreement between the abstractions on which the LLM operates and the existing abstractions in conventional symbolic programming.

We introduce LLMs as new code constructs and provide syntax support for it at the programming language level.
We also introduce a new type called that serves as the abstractions with which LLM interact with.
We define as the semantic purpose underlying or intended by the symbolic data (strings) that serve as the input and output of the LLMs.
With in hand, we define the process of translating between conventional code constructs such as variables and functions and as the process of Meaning-type Transformations (MTT).
Figure  1 right visualizes this concept.
We propose that MTT should be automated by the language runtime and abstracted away from the developers to reduce complexity.
To that end, we introduce a novel language feature called Semantic Strings (semstrings) that allow developers to flexibly provide additional context and information to existing conventional code constructs.
We show, via real code examples, how an Automatic Meaning-type Transformation (A-MTT) can be applied to streamline leveraging LLMs for three of the most common symbolic code operations: instantiating an object of a custom type, a standalone function call and member method of a class.
We make the following contributions:

-
•

We introduce a novel abstraction of treating LLMs as  meaning -type wrapped code constructs for seamless integration into conventional symbolic programming.

-
•

We introduce a new language-level feature that allow developers to annotate existing code constructs with additional context.

-
•

We propose a new runtime feature, Automatic Meaning-type Transformation, that abstracts away many of the current complexity of programming with LLMs.

## II Problem

There has been a surge in interest across the programming community in adopting GenAI models to introduce new intelligent features to their programs.
Many libraries [ 3 , 2 ] , frameworks [ 4 , 5 ] and new programming models and languages have been introduced recently to help facilitate integrating GenAI models, focusing particularly on LLMs.
However, these approaches mainly operate with a key principled concept that LLMs are essentially black-box functions that take text as input (prompt) and generate text as output.
As a result, the resulting application implementation is often two disjoint sections of a single program.
On one side of the program is the conventional symbolic code which is often large-scale pre-existing code of an application, and on the other side, is the execution of the LLM.
Connecting the two sides is often complex and convoluted string manipulation logic that is required to construct the input text to the LLM and parse the output text from the LLM.
This leads to significant complexity in the implementation and greatly impacts the readability and maintainability of the program as a whole.
While some techniques [ 2 , 5 ] try to alleviate this complexity with new abstractions and language syntax, developers are often still required to heavily refactor their existing code to gather all the necessary information to pass in and out of this text-centric interface, which further exacerbates this issue.

We think that the complexity of programming with GenAI models is rooted in the fundamental disagreement of abstractions between the traditional symbolic-programming paradigm and neuro-programming paradigm with GenAI models.
We argue that, for LLMs, the textual interface is the manifestation of a more fundamental abstraction with which LLMs operate.
Properly defining this abstraction is the key to effectively programming in a neurosymbolic way and truly unlocking the potential of these powerful GenAI models.
In the following sections of this paper, we define such an abstraction,  Meaning , and introduce  Meaning-type Transformation , a new language feature that serves as a seamless interface between symbolic programs and neuro programs with LLMs that optimizes the complexity away from the developers.

## III LLMs are Meaning-typed Code Construct

We propose that LLMs should be reasoned as a new type of code construct and treated as a first-degree citizen of the program language.
We lay out this concept and our reasoning for it in this section.

### III-A Conventional Code Constructs

Figure 2: Code constructs in symbolic programs (value, type, variable)

Figure 3: New code constructs in Neuro-symbolic programs (Meaning, LLM)

We first define existing code constructs that developers are familiar with in conventional symbolic programming.
Figure  2 shows these code constructs, including type (T), typed-value (V-T) and variable (V-T with label).
Conventional symbolic programs perform operations that transform tuples of typed-values to other tuples of typed-values with desired behaviors.
We define these operations as Operational Typed-value Transformations (OTT).
Examples of OTTs are functions and methods.
The input and output of OTTs are tuples of typed-values (Figure  1 a).

### III-B LLMs are Meaning-typed Code Constructs

Figure 4: Examples of  meaning of traditional code constructs in symbolic programs.

Since adoption, LLMs have been treated similarly to existing OTTs (e.g., functions) with strings (i.e., text) as their inputs and outputs.
Recent research focus on optimizing the process of constructing the input strings and parsing the output strings of LLMs [ 2 , 4 ] .
We argue that LLMs differ from conventional OTTs in three key aspects and should be considered as a new code construct.

First, on a fundamental level, language models do not operate on text, but instead operate on what the text  means .
Language models understand the intent of input, conduct reasoning and generate an output that represents its thoughts and conclusions.
Second, the input and output to the LLMs can be arbitrarily extended and modified without requiring updates to the LLM interface.
For conventional OTTs, their interface signature often need updating to accommodate for change in the expected inputs or desired output.
Third, language models are inherently black boxes.
The runtime behavior of the language models are often implicitly encoded in its input and dynamically constructed by the LMs after understanding of the meaning of the input during execution.
Reasoning methodologies such as Chain-of-thoughts [ 6 ] and ReACT [ 7 ] are examples of this.

Considering these fundamental differences between LLMs and conventional OTTs such as functions and methods, we argue that LLM is a brand new type of code construct.
We define that the LLM code construct is  meaning-typed .
In other words, LLMs operate on  meanings .
We define  meaning as the semantic purpose underlying or intended by the symbolic data that serve as the input and output of the language models.
Figure  3 shows the annotations for these new concepts which we will use throughout this paper.

Figure  4 illustrates three examples of  meaning for a variable of a primitive type, a function and a variable of a custom type.
In the first (top) example, the  meaning of a primitive-typed variable is the description of an entity and is derived from the type, value and label (name) of the variable. Note that not only the variable names play a role in the  meaning but also their types.
For a function, its  meaning represents an action or operation and is derived from the label of the function as well as the  meaning of its input type and output type.
An combination of meanings of primitive-typed variables and functions can then be used to realise the  meaning of a variable of a custom type (i.e., class) in the last example.
Conceptualizing LLMs as a brand new code construct that is wrapped with a new special  meaning type creates a novel framework under which we should design the right solution for reducing complexity of programming with GenAI models.

## IV Bridging the Gap between Conventional and Neuro-symbolic Programming

Now that we have defined LLM as a new code construct and its interface as  meanings , we can observe that, in a neurosymbolic program, the conversions between traditional typed-values in conventional symbolic programs and  meanings is a key step in programming with GenAI models.
This conversion can be high-complexity, effort-intensive and highly impactful to the performance of the program.
In this section, we formally define this process and propose that this process to be automated by the runtime and optimized away from the developer.

### IV-A Meaning-type Transformation (MTT)

Figure 5: Meaning-type Transformations (MTT) transforms between conventional typed-values and meanings.

We define the process of conversion between symbolic typed-values and meanings as Meaning-type Transformations (MTT).
MTT has the following two general variations.

-
1.

Meaning-type Raise (MTR) transforms typed-values to meanings (Figure  5 a). MTR usually happens before the inference of an LLM. MTR can leverage any and all properties associated with a typed-value to generate its meaning, including but not limited to its type, value and label.

-
2.

Meaning-type Lower (MTL) transforms meanings to typed-values (Figure  5 b). MTL usually happens after the inference of an LLM. MTL leverages already-defined properties (e.g., type and label) about a variable to transform the meaning into the value of the variable.

### IV-B Manual Meaning-type Transformation

⬇

meaning : str = f "Write a short bio for this person,"

meaning += f "\nTheir name is {name} and they were born on {dob}" .

meaning += "\nHere are some of this accomplishments."

for k , v in accomplishments . items ():

meaning += f "On {k.strftime()},"

meaning += f "they accomplished {v}"

return llm . infer ( meaning )

Figure 6: Manual Meaning-type Transformation using existing code constructs

Meaning-type transformation is currently being conducted manually, in the form of prompt engineering.
Figure  6 shows an example of a manual MTT. In this example, we are applying MTT on the function .
Compared to relative simple nature of this LLM operation, the code and logic required for MTT for this operation is noticeable more complex and hard to read.
This illustrates the high complexity that can be introduced into existing code base from adopting LLM and transitioning to a neuro-symbolic program and its heavy impact on code maintainability and readability.
This is further exacerbated in a real large-scale application for the following reasons:

-
1.

Selecting the right typed-values to transform is non-trivial, especially in a complex application with many variables in the working space.

-
2.

For a given typed-value, selecting the proper properties and leveraging them effectively to generate a meaning that best represents the underlying intent of that typed-value can be difficult to get right. This can also vary greatly depending on the scenario.

-
3.

The complexity of MTTs in your program increases with more LLMs inference you leverage. In addition, duplicate code tends to occur when the same typed-values are utilized for different LLM inferences throughout the program where the meaning should be embedded.

-
4.

When using LLM functionality with other code constructs such as inter-dependent custom types and class methods, the complexity of the MTT process becomes extreme, which transfer the responsibility of maintaining accuracy and reliability of response to the developer.

We think that the main source of complexity for programming with GenAI models lies in designing and implementing the associated MTTs.
Well-designed MTT are crucial to the performance of the LLMs and quality of the overall application.
However, building a good MTT requires extensive hands-on experience of programming with GenAI and deep knowledge of the application.
MTTs are currently done manually, which adds to developer effort and contribute to overall application complexity.
We propose that Meaning-type Transformations should be automated for the developers.
In the remaining sections of the paper, we introduce our vision for an automated meaning-type transformations.

## V Automated Meaning-type Transformation (A-MTT)

⬇

date_of_birth : str = ’2nd May, 1989’

# Unclear the exact meaning of the variable

item : str = ’apple’

Figure 7: Meaning Manifestation in conventional coding

In order to fully bridge the gap between neurosymbolic programming and traditional programming and truly unlock the potential of GenAI, we think the translation between traditional code constructs and neurosymbolic code construct should be automated for the developers.
In this section, we introduce our vision for automated meaning-type transformation (A-MTT), which consists of new language-level features and semantics.
We demonstrate this vision by modifying and augmenting Python with new language syntax and showing code examples of GenAI-powered programs.

### V-A Representing Meaning at the Language Level

In order to automate meaning-type transformations, elements required to build the  meaning of a code section should exist within the code itself i.e. the meaning should manifest within the code.
In a well written program, fragments of the  meaning are embedded within the code as meaningful variable names, meaningful function names etc. This allows the code to become human readable which in turn becomes AI readable.
Line 2 in Figure  7 shows such an example, where the variable name is sufficient to derive the meaning of the variable.

However, in conventional coding, the existing language level abstractions that allows to embed meaning are limited.
Line 4 in Figure  7 shows a variable named .
This information, along with the type and the variable value , are not sufficient in conveying the full meaning of this entity.
Depending on the context, could carry a number of different  meanings .
This demonstrates a certain degree of lack of expressibility in modern programming languages that prohibits the runtime to fully automate transforming between symbolic code constructs and  meanings .
This limitation extends to also functions and classes.
In order to automatically infer meanings, we need to provide developers with tools to annotate symbolic code to provide rich context so they can be automatically converted to and from meanings by the language runtime.

### V-B Semantic Strings (Semstrings)

⬇

# variable : type = value

’available item to sell in the store’

item : str = ’apple’

Figure 8: Embedding meaning of variable as a semstring

We introduce Semantic Strings (semstrings), a new language feature that allows developers to annotate their symbolic code to provide additional information and context.
A semstring is a string that describe the meaning of the code construct much like comments and doc-strings.
Semstrings are free-form text that developers can write to describe a variable, function or class.
The concept of semstring is agnostic to the programming language.
In this paper, we use Python as an example to show how semstring can be implemented in a modern programming language.

Semstrings aid the programmer to provide additional context of a code construct and help clarify its meaning.
Figure  8 shows a semstring-annotated version of the example from Figure  7 .
The additional context in the semstring alleviate much of the ambiguity in the meaning of .
The same approach can be taken towards writing semstrings for object classes and functions, which will represent their operation.
Semantic strings can greatly improve code readability and can be leveraged to automatically generate the meaning of the code on which the LLMs will operate.

### V-C LLM as a Code Construct

⬇

model_name : "gpt-4"

temperature : 0.7

do_sample : true

Figure 9: GenAI models as new code constructs

We introduce GenAI models as a new language-level code construct,  model (Figure  9 ).
model operates as a keyword similar to which will define a custom model type.
The model name and other hyper-parameters can be mapped to LLM inference.
model are meaning-typed, as in they operates with meanings as their inputs and outputs.
The invocation of a type in the code will inform the language runtime to apply A-MTT to integrate LLM inference with the symbolic code portion of the program.

### V-D A-MTT in Action

We show A-MTT in action, integrating LLM inference with conventional symbolic code.
We show three use cases where LLMs can replace symbolic code and reduce code complexity: 1) instantiating objects of custom types, 2) standalone functions and 3) class member methods.
Figure  10 illustrates the three use cases.

Figure 10: Three types of A-MTTs, for Type, Function and Method.

#### V-D1 Instantiating custom typed objects

⬇

name : str

’date of birth in format : DD/MM/YYYY’

dob : str

’Accomplishments’

accomp : list [ str ]

Einstein = Person ( name = "Einstein" ) by llm ()

Figure 11: Instantiating object of a custom type using LLM

When instantiating a object of a custom type with multiple member attributes, it is common to only explicitly provide some of the attributes and use logic to infer the other attributes to fully creating the object.
This inference can be done automatically with LLM in place of more logic.
In the example given in Figure  11 , a custom type called is defined which has name, DOB and accomplishments as attributes.
When creating an object of this custom class, labeled as Einstein, it can be seen that only the has been explicitly provided as an initializing property of the object.
The remaining attributes (, ) are automatically populated by an LLM.
The LLM is invoked with the syntax .

The semstrings included in the code snippet describes the custom class and the field variables.
The class has three attributes.
is a variable which is of string type. It does not need semstring because the variable name itself is self-explanatory. and variable require semstrings to fully describe their meanings.
Upon invocation of the LLM, an Automatic Meaning-type Raise (A-MTR) process transforms the current context (including the class label of , the attributes label and semstrings of , and and the provided initialized value for attribute) into the input for the LLM.
After the LLM inference, the output is then converted into the values for the attributes and through the Automatic Meaning-type Lower (A-MTL) process.
These values are then used to fully initialize the variable .
This process is illustrated in Figure  10 middle.

#### V-D2 Standalone functions

⬇

summarize (

’Accomplishments’ a : list [ str ]

) -> summary : str by llm ()

accomp_summary = summarize ( Einstein . accomp )

Figure 12: Embedding meaning of functions using semstrings.

A function in a program can be explained as a operation that transform a set of typed-values (input parameters) to another set of typed-values (output values).
A neurosymbolic function will